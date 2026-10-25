// Real cover art for the Library/Playlists hero panes. Album artwork URLs are
// stable {w}x{h} CDN templates; playlist artwork URLs are pre-signed and expire
// in 24h (both live-probed 2026-07-14) — so bytes are cached on disk forever,
// URLs never are. Rendering reuses artworkToAscii (chafa half-blocks, mono
// fallback). Every failure degrades silently to the caller's gradient
// placeholder. Unusable artwork (a 404, an undecodable file) is negative-cached
// for the session so nothing loops; a temporary failure (timeout, network
// error, 5xx) is retried on a later ask after a per-key backoff, so a network
// blip no longer leaves a gradient until restart.
//
// Scheduling (2026-10-25): work used to run on one serial queue with a
// synchronous `Data(contentsOf:)` and no deadline, so a slow old download held
// every later cover behind it. Now: a small fixed pool (`Limits.maxConcurrent`),
// newest ask first, a bounded pending list whose oldest entries are discarded
// unstarted (art scrolled past), a dedicated URLSession with a hard deadline,
// and cancellation of an in-flight fetch nobody has asked for lately when new
// art needs its slot. The rendered-line and kitty-escape memos are byte-bounded
// LRU caches instead of unbounded dictionaries.
//
// Liveness and physical capacity (review, 2026-10-25): asks come from render,
// and `ShellRenderGate` now suppresses idle repaints, so a retry deadline or a
// stale-slot deadline can pass with no ask to act on it. The store remembers
// the latest ask as the scene's current demand, and `pump()`, which every art
// scene calls from `tick` (once per shell-loop pass, painted or not),
// re-issues that demand when its retry deadline passes and reruns the
// scheduler so a stale slot is reclaimed on time. Success fires the ask's own
// `onReady`, so the tick reports the change and the shell paints once. The
// demand belongs to the scene's current view: each scene calls
// `retainDemand(key:)` with the cover that view shows (or nil) before it pumps,
// so a cover the view has left is never re-issued (review round 2). And a
// cancelled job keeps its slot, and its key, until its body has returned: a
// render or PNG conversion cannot be cancelled, so the pool bounds the work
// actually running, not the bookkeeping.
import Foundation

/// One cover's render result: half-block text lines (the chafa/mono fallback
/// ladder, unchanged) or a kitty-protocol placement descriptor. `transmit` is
/// non-nil whenever the PNG conversion has completed — callers place
/// unconditionally but only emit the transmit escape when it's non-nil (nil
/// only while the fetch/convert is still in flight; once cached it is handed
/// out on every call, see the `kittyEscape` comment below for why).
enum ArtBlock {
    case lines([String])
    case kitty(id: UInt32, transmit: String?)
}

/// What a fetch produced. `.temporary` (timeout, connection trouble, 408, 429,
/// 5xx) is retried after a backoff; `.permanent` (404 and other 4xx, a bad URL,
/// an unreadable file, an empty body) is negative-cached for the session.
enum ArtworkFetchOutcome: Equatable {
    case data(Data)
    case temporary
    case permanent
}

/// Handed to a fetch so the store can abandon it. A fetch registers what to do
/// on cancel (the default fetch cancels its URLSession task); a handler added
/// after cancellation runs at once.
final class ArtworkFetchToken {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return }
        handlers.append(handler)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let run = handlers
        handlers = []
        lock.unlock()
        run.forEach { $0() }
    }
}

/// A string-keyed cache bounded by the summed `cost` of its values, evicting
/// the least recently used (get or set) entry first. The newest entry is never
/// evicted, even alone over budget: dropping it would only make the caller
/// rebuild it on the next frame, forever. Not thread-safe; the owner locks.
final class ByteBoundedLRU<Value> {
    private let budget: Int
    private let cost: (Value) -> Int
    private var entries: [String: (value: Value, cost: Int, used: UInt64)] = [:]
    private var clock: UInt64 = 0
    private(set) var totalBytes = 0

    init(budget: Int, cost: @escaping (Value) -> Int) {
        self.budget = budget
        self.cost = cost
    }

    func get(_ key: String) -> Value? {
        guard let e = entries[key] else { return nil }
        clock += 1
        entries[key] = (e.value, e.cost, clock)
        return e.value
    }

    func set(_ key: String, _ value: Value) {
        if let old = entries[key] { totalBytes -= old.cost }
        let c = cost(value)
        clock += 1
        entries[key] = (value, c, clock)
        totalBytes += c
        // Eviction runs only on insert and the entry count stays in the
        // hundreds at these budgets, so a linear scan for the oldest is fine.
        while totalBytes > budget, entries.count > 1,
              let victim = entries.min(by: { $0.value.used < $1.value.used })?.key, victim != key {
            totalBytes -= entries[victim]!.cost
            entries[victim] = nil
        }
    }
}

final class ArtworkStore {
    /// {w}x{h} substitution for album CDN templates; pre-signed playlist URLs
    /// contain no placeholder and pass through verbatim.
    static func resolveURL(_ template: String, width: Int, height: Int) -> String {
        template.replacingOccurrences(of: "{w}x{h}", with: "\(width)x\(height)")
    }

    /// Filesystem-safe cache key from a REST resource id.
    static func cacheKey(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// Scheduling, retry and memory bounds. Defaults, and why:
    /// - `maxConcurrent` 2: every scene shows one hero cover at a time, so two
    ///   slots let newly focused art start while one older fetch drains, and
    ///   keep chafa process spawns and PNG conversions light. A stale in-flight
    ///   fetch is cancelled outright when new art needs its slot.
    /// - `maxPending` 4: queued asks beyond the four newest are art the person
    ///   has scrolled past; they are dropped unstarted (a later ask re-queues).
    /// - `staleAfter` 2 s: a running job not asked for in this long, while the
    ///   scene is asking for something else, is no longer on screen (scenes
    ///   re-ask for the displayed cover on every paint), so it may be cancelled.
    /// - `retryBase` 10 s doubling to `retryCap` 5 min: a blip recovers on the
    ///   next ask after 10 s; a dead CDN costs about a dozen fetches an hour
    ///   per cover instead of one per frame.
    /// - `renderedBytes` 8 MB: a truecolor chafa hero is roughly 20-60 KB of
    ///   escape text, so well over a hundred renders stay warm.
    /// - `kittyBytes` 24 MB: a kitty transmit escape is the base64 of a PNG,
    ///   roughly 0.3-1.5 MB per 600x600 cover, so a few dozen covers stay warm
    ///   (an evicted one is re-converted from the disk cache, never refetched).
    ///   Both are SOFT budgets on payload bytes (UTF-8 length), against
    ///   unbounded before: the newest entry is kept even when it alone exceeds
    ///   its budget (see `ByteBoundedLRU`), and dictionary, key and String
    ///   overhead is not counted. Roughly 32 MB of payload per store, then,
    ///   not a hard ceiling on memory.
    struct Limits {
        var maxConcurrent = 2
        var maxPending = 4
        var staleAfter: TimeInterval = 2
        var retryBase: TimeInterval = 10
        var retryCap: TimeInterval = 300
        var renderedBytes = 8 << 20
        var kittyBytes = 24 << 20

        static let `default` = Limits()

        /// Cooldown after the `n`th consecutive temporary failure of one key.
        func backoff(afterFailures n: Int) -> TimeInterval {
            min(retryCap, retryBase * pow(2, Double(min(max(1, n), 40) - 1)))
        }
    }

    // MARK: default network fetch

    /// Per-packet idle bound. CDN covers are tens to a few hundred KB and
    /// normally arrive in well under a second; 8 s of silence is a stall.
    static let requestTimeout: TimeInterval = 8
    /// Hard bound on one whole fetch. `Data(contentsOf:)` ran under the shared
    /// session's 7-day resource default; 15 s is generous for a slow link and
    /// still bounded. (This is the network fetch only. It is unrelated to the
    /// SpanDAC library-cover render opportunity in `LibraryCoverFetcher`.)
    static let resourceTimeout: TimeInterval = 15

    static let networkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData   // bytes are cached on disk by the store
        config.urlCache = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Classify one URLSession completion. Pure, so it is tested without a request.
    static func classify(data: Data?, response: URLResponse?, error: Error?) -> ArtworkFetchOutcome {
        if let error {
            if let e = error as? URLError {
                switch e.code {
                case .badURL, .unsupportedURL, .fileDoesNotExist, .noPermissionsToReadFile,
                     .dataLengthExceedsMaximum:
                    return .permanent
                default:
                    return .temporary
                }
            }
            return .temporary
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 408, 429, 500...599: return .temporary
            default: return .permanent
            }
        }
        guard let data, !data.isEmpty else { return .permanent }
        return .data(data)
    }

    private final class OutcomeBox {
        private let lock = NSLock()
        private var outcome: ArtworkFetchOutcome = .temporary
        func set(_ o: ArtworkFetchOutcome) { lock.lock(); outcome = o; lock.unlock() }
        var value: ArtworkFetchOutcome { lock.lock(); defer { lock.unlock() }; return outcome }
    }

    /// The production fetch. A file URL (the library ladder's embedded-artwork
    /// path, SpanDAC library covers) is read directly and an unreadable file is
    /// permanent, as before. Anything else goes through `networkSession` with
    /// its deadline, and the token cancels the task. Runs on a store worker,
    /// never the main thread.
    static func defaultFetch(_ urlString: String, _ token: ArtworkFetchToken) -> ArtworkFetchOutcome {
        guard let url = URL(string: urlString) else { return .permanent }
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .permanent }
            return .data(data)
        }
        let done = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        let task = networkSession.dataTask(with: url) { data, response, error in
            box.set(classify(data: data, response: response, error: error))
            done.signal()
        }
        token.onCancel { task.cancel() }
        task.resume()
        // Belt and braces over the session's own resource deadline.
        if done.wait(timeout: .now() + resourceTimeout + 5) == .timedOut {
            task.cancel()
            return .temporary
        }
        return box.value
    }

    // MARK: state

    private final class Job {
        let workKey: String      // memoKey (lines) or "kitty|\(key)" (block)
        let key: String
        var seq: UInt64          // recency of the latest ask; newest runs first
        var wantedAt: TimeInterval
        var preempted = false    // cancelled, still physically running until its body returns
        let token = ArtworkFetchToken()
        let body: (Job) -> Void
        init(workKey: String, key: String, seq: UInt64, wantedAt: TimeInterval, body: @escaping (Job) -> Void) {
            self.workKey = workKey; self.key = key; self.seq = seq; self.wantedAt = wantedAt; self.body = body
        }
    }

    /// The scene's current cover: its latest ask, kept so `pump()` can re-issue
    /// it when its retry deadline passes without anyone asking again.
    private struct Demand {
        let workKey: String
        let key: String
        let body: (Job) -> Void
    }

    private let cacheDir: String
    private let fetcher: (String, ArtworkFetchToken) -> ArtworkFetchOutcome
    private let render: (String, Int, Int) -> [String]
    private let now: () -> TimeInterval
    private let limits: Limits
    private let workers = DispatchQueue(label: "music.artwork", qos: .utility, attributes: .concurrent)
    private let busy = DispatchGroup()
    private let lock = NSLock()
    private let rendered: ByteBoundedLRU<[String]>   // "\(key)|\(w)x\(h)" → lines
    private var pending: [String: Job] = [:]         // asked for, not started
    private var running: [String: Job] = [:]         // started and not yet returned, preempted or not: its count is the physical slot use
    private var activeByKey: [String: Int] = [:]     // running jobs per cache key: one per key until it physically returns
    private var demand: Demand?                      // latest ask not yet satisfied (see `pump`)
    private var askSeq: UInt64 = 0
    private var failed: Set<String> = []             // per-session negative cache (unusable bytes OR PNG conversion)
    private var temporaryFailures: [String: Int] = [:]  // consecutive temporary failures per key
    private var retryAt: [String: TimeInterval] = [:]   // no fetch for this key before this time
    // Kitty path: the transmit escape is built once per key (PNG conversion is
    // the expensive part) and cached here. It USED to be handed out exactly
    // once per id (a `transmitted: Set<UInt32>` gate returned `.kitty(id:,
    // transmit: nil)` on every call after the first), on the theory that
    // `d=i` (lowercase delete, KittyGraphics.kittyDeleteEscape) keeps the
    // image data resident so a bare `a=p` could re-display it later without
    // re-sending bytes. Shipped in 3.6.0, confirmed broken live (both Radio
    // and Library tabs): scroll away from a cover and back, and it never
    // reappears — either the terminal frees the data anyway or `a=p` isn't
    // honored for an id that isn't currently placed. DO NOT reintroduce a
    // once-per-id transmit gate here. The escape is cheap to re-emit (it's
    // just re-sending already-converted PNG bytes to a local terminal); the
    // expensive PNG conversion itself stays cached below regardless. The
    // caller-side placement dedup (see `renderArtHero` / each scene's
    // `lastPlaced`) already prevents re-transmitting on unchanged frames —
    // this only fires again when the displayed cover actually changes.
    // Byte-bounded LRU since 2026-10-25: an evicted escape is rebuilt from the
    // disk cache on the next ask (a brief gradient), never refetched.
    private let kittyEscape: ByteBoundedLRU<String>  // key → cached transmit escape

    /// The art cache on disk. One definition, because `LibraryCoverFetcher`
    /// installs SpanDAC's library covers into the same directory (under `sd_`
    /// keys) for this store to find without fetching.
    static let defaultCacheDir = NSString(string: "~/.config/music/art-cache").expandingTildeInPath

    /// `fetcher` is the full seam (outcome classes, cancellation). `fetch` is
    /// the older one, kept for its tests: a nil is a permanent failure, exactly
    /// what it always meant. With neither, `defaultFetch` runs.
    init(cacheDir: String = ArtworkStore.defaultCacheDir,
         fetch: ((String) -> Data?)? = nil,
         fetcher: ((String, ArtworkFetchToken) -> ArtworkFetchOutcome)? = nil,
         render: ((String, Int, Int) -> [String])? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         limits: Limits = .default) {
        self.cacheDir = cacheDir
        if let fetcher {
            self.fetcher = fetcher
        } else if let fetch {
            self.fetcher = { url, _ in fetch(url).map { .data($0) } ?? .permanent }
        } else {
            self.fetcher = ArtworkStore.defaultFetch
        }
        self.render = render ?? { path, w, h in artworkToAscii(path: path, width: w, height: h) }
        self.now = now
        self.limits = limits
        self.rendered = ByteBoundedLRU(budget: limits.renderedBytes) { lines in
            lines.reduce(0) { $0 + $1.utf8.count }
        }
        self.kittyEscape = ByteBoundedLRU(budget: limits.kittyBytes) { $0.utf8.count }
    }

    /// Act on deadlines without an ask. Scenes call this from `tick`, which
    /// the shell runs on every loop pass whether or not it paints. Two
    /// deadlines: the current cover's retry cooldown (a temporary failure),
    /// after which its ask is re-issued as if the scene had painted again; and
    /// the stale window, after which the scheduler may reclaim a slot held by
    /// art nobody is asking for. A cover that lands fires its ask's `onReady`,
    /// so the scene's next tick reports the change and the shell paints once.
    /// Cheap when idle: a lock and two dictionary reads.
    func pump() {
        lock.lock()
        if let d = demand {
            if failed.contains(d.key) {
                demand = nil
            } else if let at = retryAt[d.key], now() >= at,
                      pending[d.workKey] == nil, running[d.workKey].map({ $0.preempted }) ?? true {
                askLocked(workKey: d.workKey, key: d.key, body: d.body)
            }
        }
        guard !pending.isEmpty else { lock.unlock(); return }
        let next = scheduleLocked()
        lock.unlock()
        next.cancel.forEach { $0.cancel() }
        next.start.forEach(launch)
    }

    /// The scene is showing no store cover now (focus moved to a row with no
    /// artwork, a source with no cover): stop retrying the last one. Queued
    /// and running work is left to the scheduler's own rules.
    func dropDemand() {
        lock.lock(); demand = nil; lock.unlock()
    }

    /// The scene's CURRENT view wants `rawKey`'s cover (nil: no store cover).
    /// Scenes call this at the top of `tick`, after their own provenance and
    /// focus decisions and BEFORE `pump()`, so a demand left by a view that is
    /// gone (another row, sub-view or source, an empty or coverless view, a
    /// return to a tab that now shows something else) is revoked before the
    /// pump can re-issue it. An unchanged cover keeps its demand, so an idle
    /// screen still recovers. A revoked demand's job that has not started is
    /// dropped unsent; one already running keeps its slot (`launch`).
    func retainDemand(key rawKey: String?) {
        lock.lock()
        if let d = demand, rawKey.map(Self.cacheKey) != d.key {
            demand = nil
            pending[d.workKey] = nil
        }
        lock.unlock()
    }

    /// Blocks until every started job has finished. Tests only.
    func waitUntilIdleForTesting() { busy.wait() }

    // MARK: failure bookkeeping

    /// Negative-cache `key` for the session, EXCEPT an `sd_` key (a local file
    /// `LibraryCoverFetcher` installed and may evict on its own) whose file is
    /// missing right now: that failure is the eviction racing this read, not a
    /// bad cover, and a later reinstall of the same key must still render. A
    /// present-but-undecodable `sd_` file, and every other key, is negative-cached
    /// as always so nothing loops.
    private func noteFailure(_ key: String) {
        if key.hasPrefix("sd_"), !FileManager.default.fileExists(atPath: "\(cacheDir)/\(key)") { return }
        lock.lock(); failed.insert(key); lock.unlock()
    }

    /// A temporary failure: no negative cache, just a cooldown that doubles
    /// with each consecutive one, so the next ask after it fetches again.
    private func noteTemporaryFailure(_ key: String) {
        lock.lock()
        let n = (temporaryFailures[key] ?? 0) + 1
        temporaryFailures[key] = n
        retryAt[key] = now() + limits.backoff(afterFailures: n)
        lock.unlock()
    }

    /// Caller holds `lock`.
    private func isBlockedLocked(_ key: String) -> Bool {
        if failed.contains(key) { return true }
        if let at = retryAt[key], now() < at { return true }
        return false
    }

    private enum BytesResult { case path(String), failed, abandoned }

    /// Ensure `key`'s raw artwork bytes are cached to disk (fetching on a
    /// miss) and return the local path. A permanent failure is negative-cached
    /// in `failed` (subject to the `sd_` rule), a temporary one starts a
    /// cooldown, and a fetch the store cancelled records nothing (any bytes it
    /// still produced are kept on disk). Both the chafa/mono path (`lines`)
    /// and the kitty path (`block`) share this.
    private func ensureBytesOnDisk(key: String, url: String, token: ArtworkFetchToken) -> BytesResult {
        let path = "\(cacheDir)/\(key)"
        if FileManager.default.fileExists(atPath: path) { return .path(path) }
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let outcome = fetcher(url, token)
        if token.isCancelled {
            if case .data(let data) = outcome, !data.isEmpty {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            return .abandoned
        }
        switch outcome {
        case .data(let data) where !data.isEmpty:
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            lock.lock(); temporaryFailures[key] = nil; retryAt[key] = nil; lock.unlock()
            return .path(path)
        case .temporary:
            noteTemporaryFailure(key)
            return .failed
        case .data, .permanent:
            noteFailure(key)
            return .failed
        }
    }

    // MARK: scheduling

    /// Record an ask for `workKey`. Caller holds `lock`. A repeat ask refreshes
    /// the job's recency (pending: runs sooner; running: not stale). A new ask
    /// beyond `maxPending` queued drops the oldest queued ones unstarted.
    private func askLocked(workKey: String, key: String, body: @escaping (Job) -> Void) {
        askSeq += 1
        let t = now()
        // A cancelled job that has not returned yet is not coalesced into: its
        // result is abandoned, so the ask queues afresh and starts once the old
        // body has retired (the per-key rule holds it until then).
        if let job = pending[workKey] ?? running[workKey].flatMap({ $0.preempted ? nil : $0 }) {
            job.seq = askSeq; job.wantedAt = t
            return
        }
        pending[workKey] = Job(workKey: workKey, key: key, seq: askSeq, wantedAt: t, body: body)
        while pending.count > max(1, limits.maxPending),
              let oldest = pending.values.min(by: { $0.seq < $1.seq }) {
            pending[oldest.workKey] = nil
        }
    }

    /// Start what can start, newest ask first. Caller holds `lock`; the caller
    /// cancels the returned tokens and launches the returned jobs after
    /// unlocking. When every slot is busy, a running job asked for less
    /// recently than the waiting one, and not asked for in `staleAfter`, is
    /// preempted: its token is cancelled, but it keeps its slot and its key
    /// until its body returns (`launch`), because a render or PNG conversion
    /// runs to completion whatever the token says. A slot already being freed
    /// that way is promised to the newest waiting job, so one waiting job
    /// cancels at most one victim.
    private func scheduleLocked() -> (start: [Job], cancel: [ArtworkFetchToken]) {
        var start: [Job] = []
        var cancel: [ArtworkFetchToken] = []
        let slots = max(1, limits.maxConcurrent)
        var freeing = running.values.filter { $0.preempted }.count
        let t = now()
        for next in pending.values.sorted(by: { $0.seq > $1.seq }) {
            guard activeByKey[next.key, default: 0] == 0 else { continue }
            if running.count < slots {
                pending[next.workKey] = nil
                running[next.workKey] = next
                activeByKey[next.key, default: 0] += 1
                busy.enter()
                start.append(next)
                continue
            }
            if freeing > 0 { freeing -= 1; continue }
            guard let victim = running.values
                .filter({ !$0.preempted && $0.seq < next.seq && t - $0.wantedAt >= limits.staleAfter })
                .min(by: { $0.seq < $1.seq }) else { break }
            victim.preempted = true
            cancel.append(victim.token)
        }
        return (start, cancel)
    }

    /// The job's body has returned: its slot and its key are free. Caller holds `lock`.
    private func releaseLocked(_ job: Job) {
        if running[job.workKey] === job { running[job.workKey] = nil }
        let n = (activeByKey[job.key] ?? 1) - 1
        activeByKey[job.key] = n > 0 ? n : nil
    }

    private func launch(_ job: Job) {
        workers.async {
            job.body(job)
            self.lock.lock()
            self.releaseLocked(job)
            let next = self.scheduleLocked()
            self.lock.unlock()
            next.cancel.forEach { $0.cancel() }
            next.start.forEach(self.launch)
            self.busy.leave()   // after any successor entered, so idle means idle
        }
    }

    /// Ask, schedule, and launch outside the lock. Caller holds `lock`; this
    /// releases it.
    private func askAndUnlock(workKey: String, key: String, body: @escaping (Job) -> Void) {
        askLocked(workKey: workKey, key: key, body: body)
        let next = scheduleLocked()
        lock.unlock()
        next.cancel.forEach { $0.cancel() }
        next.start.forEach(launch)
    }

    // MARK: public API

    /// Rendered cover lines if ready, else nil — and a background fetch+render
    /// is kicked (once per key+size while it is queued or running); `onReady`
    /// fires from a store worker when lines land. Callers repaint on their
    /// next tick and get the memory hit.
    func lines(key rawKey: String, url: String, width: Int, height: Int,
               onReady: @escaping () -> Void) -> [String]? {
        let key = Self.cacheKey(rawKey)
        let memoKey = "\(key)|\(width)x\(height)"
        lock.lock()
        if let hit = rendered.get(memoKey) { demand = nil; lock.unlock(); return hit }
        let body: (Job) -> Void = { [unowned self] job in
            guard case .path(let path) = self.ensureBytesOnDisk(key: key, url: url, token: job.token),
                  !job.token.isCancelled else { return }
            let lines = self.render(path, width, height)
            if lines.isEmpty { self.noteFailure(key); return }
            self.lock.lock()
            self.rendered.set(memoKey, lines)
            if self.demand?.workKey == memoKey { self.demand = nil }
            self.lock.unlock()
            onReady()
        }
        demand = Demand(workKey: memoKey, key: key, body: body)
        if isBlockedLocked(key) { lock.unlock(); return nil }
        askAndUnlock(workKey: memoKey, key: key, body: body)
        return nil
    }

    /// Same fetch/cache contract as `lines()`, but for the kitty graphics
    /// protocol: `kitty: false` is exactly today's `lines()` flow wrapped in
    /// `.lines`. `kitty: true` ensures bytes are on disk, converts them to PNG
    /// off the main thread (the protocol's direct-transmit format is PNG-only;
    /// cached bytes are JPEG — design doc sharp edge #2), and returns a stable
    /// id + the cached transmit escape on EVERY call once the PNG is ready
    /// (see the `kittyEscape` comment above for why it's no longer gated to
    /// once per id). PNG conversion failure is treated like a render failure:
    /// negative-cached in `failed`, same as a permanent fetch failure. While
    /// bytes/PNG aren't ready yet, returns nil and fires `onReady` later, same
    /// as `lines()`.
    func block(key rawKey: String, url: String, width: Int, height: Int,
               kitty: Bool, onReady: @escaping () -> Void) -> ArtBlock? {
        guard kitty else {
            return lines(key: rawKey, url: url, width: width, height: height, onReady: onReady).map { .lines($0) }
        }
        let key = Self.cacheKey(rawKey)
        let id = kittyImageID(forKey: key)

        let workKey = "kitty|\(key)"
        lock.lock()
        if let escape = kittyEscape.get(key) {
            demand = nil
            lock.unlock()
            return .kitty(id: id, transmit: escape)
        }
        let body: (Job) -> Void = { [unowned self] job in
            // ensureBytesOnDisk has already decided whether a failed fetch is
            // negative-cached; only the read and the PNG conversion are decided here.
            guard case .path(let path) = self.ensureBytesOnDisk(key: key, url: url, token: job.token),
                  !job.token.isCancelled else { return }
            guard let data = FileManager.default.contents(atPath: path),
                  let png = imageDataToPNG(data) else {
                self.noteFailure(key)
                return
            }
            let escape = kittyTransmitEscape(id: id, png: png)
            self.lock.lock()
            self.kittyEscape.set(key, escape)
            if self.demand?.workKey == workKey { self.demand = nil }
            self.lock.unlock()
            onReady()
        }
        demand = Demand(workKey: workKey, key: key, body: body)
        if isBlockedLocked(key) { lock.unlock(); return nil }
        askAndUnlock(workKey: workKey, key: key, body: body)
        return nil
    }
}


/// One scene's kitty placement-dedup state: the last placement it emitted, so
/// an unchanged frame emits nothing (the placement persists on screen across
/// text repaints) and a changed one deletes the old placement before drawing
/// the new one. Each art-rendering scene keeps exactly one, reset to nil in
/// `artPlacementsInvalidated()`.
typealias ArtPlacement = (id: UInt32, row: Int, col: Int, cols: Int, rows: Int)

/// Render one hero art block — kitty placement, chafa/mono lines, or the
/// gradient identicon fallback — into `out` at column `x` starting at row
/// `startY`. Shared by every hero pane (LibraryScene, PlaylistsScene, and now
/// RadioScene each need this exact ladder) so the kitty aspect-clamp lives in
/// one place instead of being copy-pasted per scene: kitty placement
/// STRETCHES to the cell rect while chafa letterboxes, so the rect is clamped
/// to square-equivalent IN PIXELS for the caller's measured `cellW`/`cellH`
/// (see `kittySquareRect` in KittyGraphics.swift) — assuming a fixed 1:2 cell
/// aspect measured wrong on a real terminal (docs/playbook.md Gotchas).
///
/// `lastPlaced` is the caller's own placement-dedup state; this returns the
/// row past the rendered art plus the new placement value for the caller to
/// store. `gradientSeedText` seeds the deterministic gradient fallback and
/// its tint. Nothing here ever throws or errors at the user — art is
/// decoration, and `.none` always degrades to the gradient block.
func renderArtHero(artBlock: ArtBlock?, gradientSeedText: String,
                   gw: Int, gh: Int, x: Int, y startY: Int,
                   cellW: Double, cellH: Double,
                   lastPlaced: ArtPlacement?,
                   into out: inout String) -> (y: Int, lastPlaced: ArtPlacement?) {
    var y = startY
    var placed = lastPlaced
    // The square-equivalent rect every branch below must agree on: kitty
    // stretches to it, the placeholder is drawn at exactly it, and chafa
    // (below) is now capped/padded to it too. Sharing one computation across
    // all three branches is what guarantees `y` lands in the same place
    // regardless of which art path actually rendered (the ONLY reason `gh`
    // used to be the advance amount — see the historical note below).
    let (pc, pr) = kittySquareRect(maxCols: gw, maxRows: gh, cellW: cellW, cellH: cellH)
    switch artBlock {
    case .lines(let art):
        if let last = placed { out += kittyDeleteEscape(id: last.id); placed = nil }
        // Pad/cap to exactly `pr` rows — the SAME square-equivalent height
        // kitty/the placeholder use, not the full reserved `gh` box. Chafa
        // was asked to fill gw x gh and, using its own (uncorrected, ~1:2)
        // font-ratio guess, typically returns MORE real rows than `pr` (a
        // real square cover at gw=54/gh=34 on this terminal's measured
        // 14x34 cells comes back ~27-28 rows, not 22) — so this genuinely
        // crops the bottom of the image rather than just trimming blank
        // padding. That's a deliberate trade: capping to `pr` keeps the
        // loading-placeholder -> loaded-art transition jump-free (both draw
        // exactly `pr` rows) and keeps every art path's footprint the same
        // shape, at the cost of a modest crop on non-kitty terminals. Was:
        // padded/capped to `gh`, which never left a gap for THIS branch on
        // its own (a full gh box was always drawn, real content or blank)
        // but only stayed gap-free by coincidence, before the .kitty/.none
        // branches below started under-drawing gh's reserved height.
        let blank = String(repeating: " ", count: gw)
        let rows = art.prefix(pr) + Array(repeating: blank, count: max(0, pr - art.count))
        for line in rows {
            out += ANSICode.moveTo(row: y, col: x) + line + ANSICode.reset
            y += 1
        }
    case .kitty(let id, let transmit):
        let current: ArtPlacement = (id: id, row: y, col: x, cols: pc, rows: pr)
        if let last = placed, last == current {
            // Unchanged: the placement from a prior frame is still on
            // screen — emit nothing (spaces would flicker under the image).
        } else {
            if let last = placed { out += kittyDeleteEscape(id: last.id) }
            // Erase the FULL reserved box (gh), not just the pr rows the
            // image actually occupies — erasing more than is drawn is safe
            // (the caller's next draw, right after `y` advances by `pr`
            // below, reuses rows pr..<gh for whatever comes next); erasing
            // less than gh would risk leaving a stale placement-era row
            // behind if a resize ever shrinks pr between frames.
            let blank = String(repeating: " ", count: gw)
            for i in 0..<gh {
                out += ANSICode.moveTo(row: y + i, col: x) + blank
            }
            out += transmit ?? ""
            out += ANSICode.moveTo(row: y, col: x) + kittyPlaceEscape(id: id, cols: pc, rows: pr)
            placed = current
        }
        // Advance by what was actually drawn (pr), not the full reserved
        // box (gh) — advancing by gh here left a dead gap between the cover
        // and everything below it once gh (the hero's now-unclamped height)
        // grew past pr (the art's true square-clamped height).
        y += pr
    case .none:
        if let last = placed { out += kittyDeleteEscape(id: last.id); placed = nil }
        // Same square rect a real kitty cover would occupy — a real cover and
        // the placeholder must be pixel-for-pixel the same shape (see the
        // `.kitty` case above). `y` now advances by `pr`, same as `.kitty`
        // and `.lines`, so the metadata drawn below the art doesn't shift
        // depending on which of the three art paths rendered.
        let gradient = gradientBlock(name: gradientSeedText, width: pc, height: pr)
        for (i, line) in gradient.enumerated() {
            out += ANSICode.moveTo(row: y + i, col: x) + line
        }
        y += pr
    }
    return (y, placed)
}

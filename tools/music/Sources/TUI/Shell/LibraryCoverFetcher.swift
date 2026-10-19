// tools/music/Sources/TUI/Shell/LibraryCoverFetcher.swift
import CryptoKit
import Foundation

// SpanDAC's covers for the Albums and Playlists lists and an artist's albums: ONE fetcher for
// the shell, shared by both scenes. A scene names the row it has focused every
// tick (`focus`); after 250 ms of rest the fetcher reads `slice.status`, and when
// SpanDAC serves `slice.libraryArtwork` under the very instance the row's list
// page came from, asks for that one cover, assembles and verifies it (C1's
// `LibraryArtworkAssembly`) and installs it atomically into ArtworkStore's cache
// directory, where the hero's existing art pipeline reads it like any other
// cached cover. Nothing is posted to the status line and nothing is ever handed
// to ArtworkStore that is not already on disk.
//
// No callback reaches a scene. `landed` moves on every change that can alter a
// `cover(for:)` answer; a scene repaints when the value it last saw differs.
//
// Fail-closed: a cover shows only while a `slice.status` read within the last
// 5.0 s confirmed the op is advertised AND names the target's own instance. A row
// observed under one SpanDAC process is never asked for, and never shows a cover,
// once status names another.

/// Disk bounds for installed covers, `sd_*` files only: everything else in the art
/// cache is ArtworkStore's and never touched here.
struct LibraryCoverEviction: Equatable {
    /// Files older than this go first, every pass.
    let maximumAge: TimeInterval
    /// Over either trigger, the oldest go until both targets hold.
    let triggerFiles: Int
    let triggerBytes: Int
    let targetFiles: Int
    let targetBytes: Int
    /// A pass runs at init and after every this-many installs.
    let everyInstalls: Int

    static let standard = LibraryCoverEviction(maximumAge: 30 * 86_400,
                                               triggerFiles: 1_500, triggerBytes: 48 * 1_048_576,
                                               targetFiles: 1_200, targetBytes: 38 * 1_048_576,
                                               everyInstalls: 25)
}

final class LibraryCoverFetcher {

    /// Which scene a target belongs to, so a focus from a scene that is not the
    /// active tab is ignored.
    enum Owner: Hashable {
        case libraryAlbums, libraryArtistAlbums, playlists

        var scene: SceneID {
            switch self {
            case .libraryAlbums, .libraryArtistAlbums: return .library
            case .playlists:                           return .playlists
            }
        }
    }

    /// One focused top-level Bridge row. `generation` and `libraryInstance` are the
    /// scene's APPLIED list drain's, sent back unchanged; a status value never
    /// replaces them. `dataEpoch` is the routing coordinator's when the scene
    /// built the target.
    struct Target: Hashable {
        let owner: Owner
        let kind: LibraryArtworkKind
        let id: String
        let generation: Int
        let libraryInstance: String
        let dataEpoch: Int
    }

    /// Where background work runs: `status` for readiness reads, `fetch` for cover
    /// transfers and disk eviction. Each lane is serial. A test seam: production
    /// uses `dispatchLanes()`, a test runs jobs inline or holds them.
    enum Lane { case status, fetch }

    // The contract's client numbers (score, "Numbers").
    static let rest: TimeInterval = 0.25
    static let readinessValidity: TimeInterval = 5.0
    static let readinessRenewal: TimeInterval = 4.0
    static let readinessRetries: [TimeInterval] = [1, 2, 4, 8]
    static let unsupportedReread: TimeInterval = 30
    static let transientBackoff: TimeInterval = 30
    static let minimumWarmingRetry: TimeInterval = 1

    /// The installed file's name for a target: `sd_` + the first 32 hex of
    /// sha256(`v1|<instance>|<generation>|<kind>|<id>|<px>`). Letters, digits and
    /// `_` only, so `ArtworkStore.cacheKey` leaves it unchanged and the store finds
    /// the file without fetching. No id or instance in clear.
    static func cacheKey(for target: Target, px: Int) -> String {
        let text = "v1|\(target.libraryInstance)|\(target.generation)|\(target.kind.rawValue)|\(target.id)|\(px)"
        let hex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "sd_" + hex.prefix(32)
    }

    /// Two serial queues, one per lane.
    static func dispatchLanes() -> (Lane, @escaping () -> Void) -> Void {
        let status = DispatchQueue(label: "music.librarycovers.status", qos: .utility)
        let fetch = DispatchQueue(label: "music.librarycovers.fetch", qos: .utility)
        return { lane, job in (lane == .status ? status : fetch).async(execute: job) }
    }

    private let provider: () -> MusicDataProvider?
    private let dataEpoch: () -> Int
    private let cacheDir: String
    private let now: () -> Date
    private let queue: (Lane, @escaping () -> Void) -> Void
    private let px: Int
    private let eviction: LibraryCoverEviction

    /// A successful `slice.status` read.
    private struct Readiness {
        let supported: Bool
        let instance: String?
        let validatedAt: Date
    }

    /// What `cover(for:)` can answer from readiness alone; a change moves `landed`.
    private struct Validity: Equatable {
        let supported: Bool
        let instance: String?
        let fresh: Bool
    }

    /// The newest cover installed this session for one row, whatever generation.
    private struct InterimKey: Hashable {
        let instance: String
        let kind: LibraryArtworkKind
        let id: String
    }

    private enum RestPhase { case resting, readDue, reading, done }

    /// The list a `stale_generation` refusal named: the generation and instance a
    /// target carried when SpanDAC said its snapshot had moved on.
    struct StaleList: Hashable {
        let generation: Int
        let libraryInstance: String
    }

    /// The bookkeeping of a scene that reads its list again in place when SpanDAC
    /// left it behind: a `stale_generation` refusal naming the applied list, or a
    /// restart, a readiness instance other than the applied one. Albums, Playlists
    /// and an artist's albums share it; each scene supplies its own read and guards.
    ///
    /// Each reason (a stale list; a pair of instances) is read for ONCE when the
    /// read SUCCEEDS, whatever it comes back carrying: a read that lands the same
    /// identity is not asked again. A read that FAILS (the provider timed out, the
    /// reply was discarded) is retried, but never on a tick: after `retryDelays`
    /// seconds, one delay per retry, so at most `1 + retryDelays.count` attempts
    /// and then it is spent until the list changes. An attempt in flight is not
    /// asked again; one whose outcome never arrives (its worker was superseded)
    /// counts as a failure after `inFlightBound`, once: that claim is REVOKED, so
    /// its late failure, success or release is a no-op and cannot touch the attempt
    /// that replaced it. Every claim carries a serial and only the reason's active
    /// serial is heard. `reset()` forgets everything and makes any outcome still to
    /// arrive from before it a no-op.
    ///
    /// A class: the outcome arrives on the read's own thread, the asking on the tick.
    final class ListReread {
        static let retryDelays: [TimeInterval] = [5, 15, 45]
        static let inFlightBound: TimeInterval = 700

        enum Reason: Hashable {
            case stale(StaleList)
            case restart(applied: String, ready: String)
        }

        private struct Attempt {
            var inFlightSince: Date?
            /// The claim in flight: only its ticket may release or finish it.
            var serial: Int?
            var failures = 0
            /// A failure the tick has not yet stamped with its retry time (the
            /// outcome's thread does not read the clock).
            var failedUnstamped = false
            var notBefore: Date?
            var done = false
        }

        private let lock = NSLock()
        private var attempts: [Reason: Attempt] = [:]
        private var generation = 0
        private var nextSerial = 0

        /// A claim on the reasons one read answers; hand it back with the outcome.
        struct Ticket {
            fileprivate let generation: Int
            fileprivate let serial: Int
            let reasons: [Reason]
        }

        struct Due {
            let reasons: [Reason]
            var any: Bool { !reasons.isEmpty }
        }

        /// What, if anything, calls for a re-read of the `applied` list now.
        func due(applied: StaleList, staleRefusal: StaleList?, readyInstance: String?, now: Date) -> Due {
            lock.lock(); defer { lock.unlock() }
            var out: [Reason] = []
            if staleRefusal == applied, eligible(.stale(applied), now: now) { out.append(.stale(applied)) }
            if let ready = readyInstance, ready != applied.libraryInstance {
                let r = Reason.restart(applied: applied.libraryInstance, ready: ready)
                if eligible(r, now: now) { out.append(r) }
            }
            return Due(reasons: out)
        }

        private func eligible(_ reason: Reason, now: Date) -> Bool {
            guard var a = attempts[reason] else { return true }
            defer { attempts[reason] = a }
            if a.done { return false }
            if let since = a.inFlightSince {
                guard now.timeIntervalSince(since) >= Self.inFlightBound else { return false }
                a.inFlightSince = nil; a.serial = nil   // revoked: its outcome is no longer heard
                a.failures += 1; a.failedUnstamped = true
            }
            if a.failedUnstamped {
                a.failedUnstamped = false
                a.notBefore = a.failures <= Self.retryDelays.count
                    ? now.addingTimeInterval(Self.retryDelays[a.failures - 1]) : .distantFuture
            }
            if let nb = a.notBefore { return now >= nb }
            return true
        }

        /// Claim `due` before the read is asked for: its outcome may arrive before
        /// the asking returns. A read that is not taken is handed back with `release`.
        func began(_ due: Due, now: Date) -> Ticket {
            lock.lock(); defer { lock.unlock() }
            nextSerial += 1
            for r in due.reasons {
                var a = attempts[r] ?? Attempt()
                a.inFlightSince = now
                a.serial = nextSerial
                attempts[r] = a
            }
            return Ticket(generation: generation, serial: nextSerial, reasons: due.reasons)
        }

        /// The read was not taken: nothing was attempted.
        func release(_ ticket: Ticket) {
            lock.lock(); defer { lock.unlock() }
            guard ticket.generation == generation else { return }
            for r in ticket.reasons where attempts[r]?.serial == ticket.serial {
                attempts[r]?.inFlightSince = nil; attempts[r]?.serial = nil
            }
        }

        /// Whether `ticket` is still the claim in flight for every reason it took: not
        /// expired and replaced, not released, not from before a `reset()`. A worker
        /// that posts rows asks this where it posts.
        func isActive(_ ticket: Ticket) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard ticket.generation == generation else { return false }
            return !ticket.reasons.isEmpty && ticket.reasons.allSatisfy { attempts[$0]?.serial == ticket.serial }
        }

        /// The read ended: `succeeded` is that it read and posted the list (whatever
        /// identity it carried), not that the list changed.
        func finished(_ ticket: Ticket, succeeded: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard ticket.generation == generation else { return }
            for r in ticket.reasons {
                guard var a = attempts[r], a.serial == ticket.serial else { continue }
                a.inFlightSince = nil; a.serial = nil
                if succeeded { a.done = true } else { a.failures += 1; a.failedUnstamped = true }
                attempts[r] = a
            }
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            generation += 1
            attempts = [:]
        }
    }

    private let lock = NSLock()
    // The shell's view, from `observeShell`.
    private var active: SceneID?
    private var shellDataEpoch: Int?
    // Focus and its rest.
    private var focused: Target?
    private var focusedSince = Date.distantPast
    private var focusSerial = 0
    private var restPhase = RestPhase.resting
    private var cancelEpoch = 0
    // Readiness.
    private var readiness: Readiness?
    private var lastInstance: String?
    private var readInFlight = false
    private var nextReadAt: Date?
    private var readFailures = 0
    private var forceRead = false
    private var announced: Validity?
    // Per-key outcomes, all cleared when status names another instance.
    private var negatives: Set<String> = []
    private var backoffUntil: [String: Date] = [:]
    private var warmingUntil: [String: Date] = [:]
    private var staleKeys: Set<String> = []
    /// Per owner, the list the latest `stale_generation` refusal came from. Not
    /// cleared by anything: a scene acts on it only while its APPLIED list still
    /// carries that very generation and instance, and a new list never does.
    private var staleLists: [Owner: StaleList] = [:]
    private var interims: [InterimKey: String] = [:]
    // The fetch worker: at most one job in flight, a newer submit replaces the
    // waiting one (the UpNextFillWorker pattern).
    private var pendingFetch: (() -> Void)?
    private var fetchWanted: (target: Target, token: Int)?
    private var fetchToken = 0
    private var installs = 0
    private var _landed = 0

    init(provider: @escaping () -> MusicDataProvider?, dataEpoch: @escaping () -> Int,
         cacheDir: String = ArtworkStore.defaultCacheDir, now: @escaping () -> Date = Date.init,
         queue: @escaping (Lane, @escaping () -> Void) -> Void = LibraryCoverFetcher.dispatchLanes(),
         px: Int = 512, eviction: LibraryCoverEviction = .standard) {
        self.provider = provider
        self.dataEpoch = dataEpoch
        self.cacheDir = cacheDir
        self.now = now
        self.queue = queue
        self.px = px
        self.eviction = eviction
        queue(.fetch) { [weak self] in self?.evict() }
    }

    // MARK: the scenes' and the shell's side

    /// Moves on every change that can alter a `cover(for:)` answer: an install, a
    /// negative, an interim cleared, a readiness change (including a result
    /// passing its 5.0 s deadline), a cancel.
    var landed: Int {
        lock.lock(); defer { lock.unlock() }
        noteValidityLocked(at: now())
        return _landed
    }

    /// Called by the shell, synchronously, every loop iteration before the active
    /// scene's `tick`. A different tab or data epoch from the previous call cancels
    /// at once (`cancelAll`).
    func observeShell(active: SceneID, dataEpoch: Int) {
        lock.lock(); defer { lock.unlock() }
        let moved = self.active != nil && (self.active != active || shellDataEpoch != dataEpoch)
        self.active = active
        shellDataEpoch = dataEpoch
        if moved { cancelLocked() }
    }

    /// Focus cleared, no waiting job starts, and a running one stops at its next
    /// check, installing nothing. For the shell (via `observeShell`) and for a
    /// scene's own provenance reset.
    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        cancelLocked()
    }

    /// The owning scene's focused top-level Bridge row, every tick; nil otherwise.
    /// A changed target restarts the rest. A target from a scene that is not the
    /// active tab is ignored, and one built under another data epoch focuses
    /// nothing.
    func focus(_ target: Target?) {
        lock.lock()
        if target == nil || target?.owner.scene == active {
            let wanted = target.flatMap { $0.dataEpoch == dataEpoch() ? $0 : nil }
            if wanted != focused {
                focused = wanted
                focusedSince = now()
                focusSerial += 1
                restPhase = .resting
            }
        }
        let work = advanceLocked()
        lock.unlock()
        run(work)
    }

    /// The cover to draw for `target`, or nil for the gradient. Nil unless
    /// readiness is valid for the target; then its own installed file, else the
    /// newest cover installed this session for the same instance, kind and id,
    /// unless SpanDAC said this generation has none.
    func cover(for target: Target) -> LibraryCover? {
        lock.lock(); defer { lock.unlock() }
        guard target.dataEpoch == dataEpoch(), validLocked(for: target, at: now()) else { return nil }
        let key = Self.cacheKey(for: target, px: px)
        if installed(key) { return libraryCover(key) }
        guard !negatives.contains(key),
              let interim = interims[interimKey(target)], installed(interim) else { return nil }
        return libraryCover(interim)
    }

    /// The list the owner's latest `stale_generation` refusal named, or nil. A scene
    /// whose applied list has exactly this generation and instance is showing rows
    /// from a snapshot SpanDAC has left, and should read its list again.
    func staleList(for owner: Owner) -> StaleList? {
        lock.lock(); defer { lock.unlock() }
        return staleLists[owner]
    }

    /// The instance the latest readiness read named, while that read said the op is
    /// supported and is still inside its validity window; nil otherwise. A scene
    /// whose applied list carries another instance is showing rows from a SpanDAC
    /// process that has gone, and should read its list again. Readiness is read
    /// only while a target is focused, and the target carries the list's own
    /// instance (never this one), so a focused row on that old list is what brings
    /// the answer.
    func readinessInstance() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let readiness, readiness.supported, let instance = readiness.instance,
              now().timeIntervalSince(readiness.validatedAt) < Self.readinessValidity else { return nil }
        return instance
    }

    // MARK: scheduling (lock held)

    private func cancelLocked() {
        focused = nil
        focusSerial += 1
        restPhase = .resting
        cancelEpoch += 1
        pendingFetch = nil
        fetchWanted = nil
        _landed += 1
    }

    /// What is due now: the rest ending, a readiness read, a cover fetch.
    private func advanceLocked() -> [(Lane, () -> Void)] {
        let t = now()
        noteValidityLocked(at: t)
        guard let target = focused else { return [] }
        if restPhase == .resting, t.timeIntervalSince(focusedSince) >= Self.rest { restPhase = .readDue }
        var work: [(Lane, () -> Void)] = []
        if let read = readJobLocked(at: t) { work.append((.status, read)) }
        if let fetch = fetchJobLocked(for: target, at: t) { work.append((.fetch, fetch)) }
        return work
    }

    /// One read at a time, only while a target is focused. Due right after a rest,
    /// when forced by `stale_generation`, when a supported result reaches 4.0 s
    /// (renewal), or at a scheduled retry; a scheduled retry also holds back the
    /// others, so nothing busy-polls.
    private func readJobLocked(at t: Date) -> (() -> Void)? {
        guard !readInFlight else { return nil }
        let due: Bool
        if let next = nextReadAt {
            due = t >= next
        } else {
            let renewal = readiness.map { $0.supported && t.timeIntervalSince($0.validatedAt) >= Self.readinessRenewal } ?? false
            due = restPhase == .readDue || forceRead || renewal
        }
        guard due else { return nil }
        readInFlight = true
        forceRead = false
        let restSerial: Int?
        if restPhase == .readDue { restPhase = .reading; restSerial = focusSerial } else { restSerial = nil }
        let epoch = cancelEpoch
        let data = dataEpoch()
        return { [weak self] in self?.read(epoch: epoch, dataEpoch: data, restSerial: restSerial) }
    }

    /// After the rest's read, with readiness valid for the target and nothing that
    /// says wait: no installed file, no negative, no backoff, no warming hint
    /// pending, no `stale_generation` for this generation, no job already for it.
    private func fetchJobLocked(for target: Target, at t: Date) -> (() -> Void)? {
        guard restPhase == .done, fetchWanted?.target != target, validLocked(for: target, at: t) else { return nil }
        let key = Self.cacheKey(for: target, px: px)
        guard !negatives.contains(key), !staleKeys.contains(key),
              backoffUntil[key].map({ t >= $0 }) ?? true,
              warmingUntil[key].map({ t >= $0 }) ?? true,
              !installed(key) else { return nil }
        fetchToken += 1
        let token = fetchToken
        let epoch = cancelEpoch
        fetchWanted = (target, token)
        pendingFetch = { [weak self] in self?.fetch(target, key: key, epoch: epoch, token: token) }
        return { [weak self] in
            guard let self else { return }
            self.lock.lock(); let job = self.pendingFetch; self.pendingFetch = nil; self.lock.unlock()
            job?()
        }
    }

    private func validLocked(for target: Target, at t: Date) -> Bool {
        guard let readiness, readiness.supported, readiness.instance == target.libraryInstance else { return false }
        return t.timeIntervalSince(readiness.validatedAt) < Self.readinessValidity
    }

    private func noteValidityLocked(at t: Date) {
        let validity = readiness.map {
            Validity(supported: $0.supported, instance: $0.instance,
                     fresh: t.timeIntervalSince($0.validatedAt) < Self.readinessValidity)
        }
        if validity != announced { announced = validity; _landed += 1 }
    }

    /// The job's check: before the first request, before every chunk request, and
    /// immediately before the rename. The data epoch is read live, so a source
    /// flip between two shell iterations is caught here too.
    private func stillNeededLocked(_ target: Target, epoch: Int) -> Bool {
        cancelEpoch == epoch && focused == target && dataEpoch() == target.dataEpoch
            && readiness?.supported == true && readiness?.instance == target.libraryInstance
    }

    private func stillNeeded(_ target: Target, epoch: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stillNeededLocked(target, epoch: epoch)
    }

    // MARK: readiness

    private func read(epoch: Int, dataEpoch data: Int, restSerial: Int?) {
        lock.lock()
        guard cancelEpoch == epoch, dataEpoch() == data, focused != nil else {
            readInFlight = false
            if restSerial == focusSerial, restPhase == .reading { restPhase = .readDue }
            lock.unlock()
            return
        }
        lock.unlock()

        var result: LibraryArtworkReadiness?
        if let provider = provider() { result = try? provider.libraryArtworkReadiness() }

        lock.lock()
        readInFlight = false
        // A cancel (tab or source change) or a data-epoch move while the call was
        // out makes its answer obsolete: an old "unsupported" would otherwise hold
        // a valid target on the gradient for `unsupportedReread`, and an old
        // transport failure would impose its retry delay on the new focus. Drop
        // it whole and let the current focus schedule its own read.
        if cancelEpoch != epoch || dataEpoch() != data {
            if restSerial == focusSerial, restPhase == .reading { restPhase = .readDue }
            // A focus built under another data epoch is dropped by the next `focus`
            // call; reading for it now would be a wasted call.
            let work = focused.map { $0.dataEpoch == dataEpoch() } == false ? [] : advanceLocked()
            lock.unlock()
            run(work)
            return
        }
        let t = now()
        if let result {
            readFailures = 0
            if result.supported, result.instance != nil {
                readiness = Readiness(supported: true, instance: result.instance, validatedAt: t)
                nextReadAt = nil
            } else {
                // Unsupported, or no instance: the gradient at once, asked again later.
                readiness = Readiness(supported: false, instance: result.instance, validatedAt: t)
                nextReadAt = t.addingTimeInterval(Self.unsupportedReread)
            }
            if let instance = result.instance {
                if let last = lastInstance, last != instance { clearOutcomesLocked() }
                lastInstance = instance
            }
        } else {
            // A transport error or timeout changes nothing: the old result expires
            // at its own deadline. Retries at 1, 2, 4, then every 8 s.
            let delay = Self.readinessRetries[min(readFailures, Self.readinessRetries.count - 1)]
            readFailures += 1
            nextReadAt = t.addingTimeInterval(delay)
        }
        if restSerial == focusSerial, restPhase == .reading { restPhase = .done }
        let work = advanceLocked()
        lock.unlock()
        run(work)
    }

    /// Another SpanDAC process: nothing learnt about the old one applies.
    private func clearOutcomesLocked() {
        negatives = []
        backoffUntil = [:]
        warmingUntil = [:]
        staleKeys = []
        interims = [:]
        _landed += 1
    }

    // MARK: the transfer (fetch lane)

    private enum Stop { case stopped, backoff, warming(TimeInterval), stale, negative, unsupported }

    private func fetch(_ target: Target, key: String, epoch: Int, token: Int) {
        defer {
            lock.lock()
            if fetchWanted?.token == token { fetchWanted = nil }
            lock.unlock()
        }
        guard let provider = provider() else { return }
        let request = LibraryArtworkRequest(kind: target.kind, id: target.id, generation: target.generation,
                                            libraryInstance: target.libraryInstance, px: px)
        var restarted = false
        while true {
            switch transfer(request, target: target, epoch: epoch, provider: provider) {
            case .success(let jpeg):
                install(jpeg, target: target, key: key, epoch: epoch)
                return
            case .failure(.restart) where !restarted:
                restarted = true
            case .failure(.restart):
                settle(.backoff, target: target, key: key, epoch: epoch)
                return
            case .failure(.stop(let stop)):
                settle(stop, target: target, key: key, epoch: epoch)
                return
            }
        }
    }

    private enum TransferFailure: Error { case restart, stop(Stop) }

    /// The first request and every chunk after it, checked before each request.
    private func transfer(_ request: LibraryArtworkRequest, target: Target, epoch: Int,
                          provider: MusicDataProvider) -> Result<Data, TransferFailure> {
        guard stillNeeded(target, epoch: epoch) else { return .failure(.stop(.stopped)) }
        let first: LibraryArtworkReply
        do {
            first = try provider.libraryArtwork(kind: request.kind, id: request.id, generation: request.generation,
                                                libraryInstance: request.libraryInstance, px: request.px)
        } catch {
            return .failure(Self.failure(thrown: error))
        }
        guard case .chunk(let chunk0) = first else {
            if case .refused(let refusal) = first { return .failure(Self.failure(refused: refusal)) }
            return .failure(.stop(.backoff))
        }
        guard var assembly = LibraryArtworkAssembly(first: chunk0, request: request) else {
            return .failure(.stop(.backoff))
        }
        while !assembly.isComplete {
            guard stillNeeded(target, epoch: epoch) else { return .failure(.stop(.stopped)) }
            guard let cursor = assembly.nextCursor else { return .failure(.stop(.backoff)) }
            let reply: LibraryArtworkReply
            do { reply = try provider.libraryArtworkChunk(cursor: cursor) }
            catch { return .failure(Self.failure(thrown: error)) }
            switch reply {
            case .refused(let refusal):
                return .failure(Self.failure(refused: refusal))
            case .chunk(let chunk):
                guard assembly.add(chunk) else { return .failure(.stop(.backoff)) }
            }
        }
        guard let jpeg = assembly.finish() else { return .failure(.stop(.backoff)) }
        return .success(jpeg)
    }

    private static func failure(refused refusal: LibraryArtworkRefusal) -> TransferFailure {
        switch refusal {
        case .warming(let retryAfter):     return .stop(.warming(retryAfter))
        case .staleGeneration:             return .stop(.stale)
        case .transferExpired:             return .restart
        case .notInLibrary, .noArtwork:    return .stop(.negative)
        case .unsupported:                 return .stop(.unsupported)
        case .renderTimeout, .renderFailed, .busy, .unlicensed, .unauthorized, .other:
            return .stop(.backoff)
        }
    }

    private static func failure(thrown error: Error) -> TransferFailure {
        if case MusicProviderError.notImplemented = error { return .stop(.unsupported) }
        return .stop(.backoff)
    }

    /// Records why a transfer ended. A cancelled job leaves no trace.
    private func settle(_ stop: Stop, target: Target, key: String, epoch: Int) {
        lock.lock(); defer { lock.unlock() }
        guard cancelEpoch == epoch else { return }
        let t = now()
        switch stop {
        case .stopped:
            break
        case .backoff:
            backoffUntil[key] = t.addingTimeInterval(Self.transientBackoff)
        case .warming(let retryAfter):
            warmingUntil[key] = t.addingTimeInterval(max(retryAfter, Self.minimumWarmingRetry))
        case .stale:
            // No retry for this generation; a new one is another key.
            staleKeys.insert(key)
            staleLists[target.owner] = StaleList(generation: target.generation,
                                                 libraryInstance: target.libraryInstance)
            forceRead = true
        case .negative:
            negatives.insert(key)
            interims[interimKey(target)] = nil
            _landed += 1
        case .unsupported:
            // Readiness false until it is read again.
            readiness = Readiness(supported: false, instance: readiness?.instance, validatedAt: t)
            nextReadAt = t.addingTimeInterval(Self.unsupportedReread)
            noteValidityLocked(at: t)
        }
    }

    /// `<key>.tmp-<pid>`, the final check, then `rename` over `<key>`. A cancel
    /// either lands before the check (nothing installed, the temp file deleted) or
    /// after the rename.
    private func install(_ jpeg: Data, target: Target, key: String, epoch: Int) {
        let path = "\(cacheDir)/\(key)"
        let temp = "\(path).tmp-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: URL(fileURLWithPath: temp))) != nil else {
            try? FileManager.default.removeItem(atPath: temp)
            settle(.backoff, target: target, key: key, epoch: epoch)
            return
        }
        lock.lock()
        guard stillNeededLocked(target, epoch: epoch) else {
            lock.unlock()
            try? FileManager.default.removeItem(atPath: temp)
            return
        }
        let renamed = rename(temp, path) == 0
        var evictNow = false
        if renamed {
            interims[interimKey(target)] = key
            installs += 1
            evictNow = installs % max(1, eviction.everyInstalls) == 0
            _landed += 1
        }
        lock.unlock()
        if !renamed {
            try? FileManager.default.removeItem(atPath: temp)
            settle(.backoff, target: target, key: key, epoch: epoch)
        }
        if evictNow { queue(.fetch) { [weak self] in self?.evict() } }
    }

    // MARK: disk

    /// `sd_*` only: files past the maximum age, then, once over a trigger, the
    /// oldest by modification time until both targets hold.
    private func evict() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cacheDir) else { return }
        var files: [(path: String, modified: Date, size: Int)] = names.filter { $0.hasPrefix("sd_") }.compactMap {
            let path = "\(cacheDir)/\($0)"
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return (path, modified, (attributes[.size] as? NSNumber)?.intValue ?? 0)
        }
        let t = now()
        var removed = 0
        files = files.filter {
            guard t.timeIntervalSince($0.modified) > eviction.maximumAge else { return true }
            if (try? fm.removeItem(atPath: $0.path)) != nil { removed += 1 }
            return false
        }
        var count = files.count
        var bytes = files.reduce(0) { $0 + $1.size }
        if count > eviction.triggerFiles || bytes > eviction.triggerBytes {
            let oldestFirst = files.sorted { ($0.modified, $0.path) < ($1.modified, $1.path) }
            for file in oldestFirst {
                if count <= eviction.targetFiles && bytes <= eviction.targetBytes { break }
                if (try? fm.removeItem(atPath: file.path)) != nil { removed += 1 }
                count -= 1
                bytes -= file.size
            }
        }
        if removed > 0 { lock.lock(); _landed += 1; lock.unlock() }
    }

    private func installed(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(cacheDir)/\(key)")
    }

    private func libraryCover(_ key: String) -> LibraryCover {
        LibraryCover(key: key, url: URL(fileURLWithPath: "\(cacheDir)/\(key)").absoluteString)
    }

    private func interimKey(_ target: Target) -> InterimKey {
        InterimKey(instance: target.libraryInstance, kind: target.kind, id: target.id)
    }

    private func run(_ work: [(Lane, () -> Void)]) {
        for (lane, job) in work { queue(lane, job) }
    }
}

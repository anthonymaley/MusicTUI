// tools/music/Sources/TUI/Shell/BridgeListFeed.swift
// One Bridge paged list's walk and inbox — Albums or Artists (C2). Songs kept
// its own hand-rolled walk (loadSongsFromBridge, added before this slice); this
// generic class is what Albums and Artists share instead of two more copies of
// the same page-by-page, restart-once, warm-up-bounded discipline slice 1
// already proved for Songs.
import Foundation

/// A `final class`, not a struct: it is shared mutable state between the
/// detached walk thread and the scene's `tick`, guarded by its own `NSLock` —
/// independent of `LibraryScene`'s `inboxLock`, because a feed is a
/// self-contained unit the scene drains from, not a participant in the
/// scene's own inbox.
final class BridgeListFeed<Row> {
    /// What `drain()` hands the scene for one tick: rows to REPLACE the list
    /// with (the first page of a fresh attempt, or nil if none landed this
    /// tick), rows to APPEND (every later page of the current attempt),
    /// Bridge's own row count once known, a failure sentence, whether Bridge
    /// answered "not ready yet" since the last drain, and whether the walk
    /// finished.
    struct Drained {
        var replace: [Row]?
        var append: [Row] = []
        var total: Int?
        var failure: String?
        var warming: Bool = false
        var done: Bool = false
        /// C2 (Revision 3, D9/D11): the latest page's `skipped_videos`, level
        /// state like `total` — read, not cleared, so a tick that lands
        /// nothing new still sees the current count. nil until a page has
        /// landed. Albums and Artists never set this above 0 (their pages
        /// default it); C3's playlist-tracks feed is what actually reads it.
        var skippedVideos: Int?
        /// The `list_rev` of the read these rows came from: level state like
        /// `total`. nil until a page has landed, when SpanDAC sent none, and
        /// once two pages of one attempt disagree (they describe different lists).
        var listRev: String?
        /// `replace` came from a stale-snapshot re-ask (`LibraryReask`) rather
        /// than from a walk's first page: the same list, read again, so the
        /// scene keeps its selection by row id instead of by index. One-shot,
        /// like `replace`.
        var reasked: Bool = false
    }

    private let lock = NSLock()
    private let fetch: (String?, Int) throws -> MusicPage
    private let map: (MusicRow) -> Row
    private let sleep: (TimeInterval) -> Void
    /// The page size this feed asks for (D4/rule 14: the client states its own
    /// request size rather than copying Bridge's maximum). Defaulted to 100,
    /// today's behaviour for Albums and Artists; a playlist's tracks feed
    /// (C3) passes Bridge's own maximum of 500.
    private let limit: Int
    /// Opt-in. The four top-level lists (Playlists, Songs, Albums, Artists) and
    /// the playlist tracks drill-in ask again when SpanDAC says its snapshot is
    /// stale. A re-ask result arrives as ONE `replace` with `reasked == true`,
    /// swapping the list under a live cursor, so the scene that opts in must
    /// follow its selected row by identity and clamp its cursor and scroll into
    /// the new count (the tracks drill-in does: row id plus occurrence among
    /// equal ids, else the numeric cursor, clamped). A list that cannot do that
    /// keeps the default of off.
    private let reasksStale: Bool

    /// Test-only completion seam: one enter per worker thread `start()` spawns,
    /// one leave when that thread ends by any route (dropped, failed, done,
    /// re-ask finished). Changes no behavior.
    private let workers = DispatchGroup()
    func waitForWorkersForTest(timeout: TimeInterval) -> Bool {
        workers.wait(timeout: .now() + timeout) == .success
    }

    private var walking = false
    /// A stale-snapshot re-ask is waiting or running (see `LibraryReask`). It
    /// holds `start()` off exactly as `walking` does — one re-ask in flight per
    /// list, never a second beside it — and is cleared by the re-ask's own end
    /// (epoch-checked, like `walking`) or by `reset()`.
    private var reasking = false
    /// What `reasking` is: a person-asked `refresh` rather than the plain
    /// stale-snapshot re-ask. A refresh is single-flight; a plain re-ask is taken
    /// over by one (see `refresh`). Meaningful only while `reasking`.
    private var refreshing = false
    /// Bumped by `reset()`. Every post the walk thread makes is checked
    /// against the epoch it started under; a mismatch means `reset()` ran
    /// since, and the post — including the walk's own ending — is dropped.
    private var epoch = 0

    private var pendingReplace: [Row]? = nil
    private var pendingAppend: [Row] = []
    private var pendingTotal: Int? = nil
    private var pendingFailure: String? = nil
    private var pendingWarming = false
    private var pendingDone = false
    private var pendingSkippedVideos: Int? = nil
    private var pendingListRev: String? = nil
    private var pendingReasked = false

    init(fetch: @escaping (String?, Int) throws -> MusicPage,
        map: @escaping (MusicRow) -> Row,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        limit: Int = 100,
        reasksStale: Bool = false) {
        self.fetch = fetch
        self.map = map
        self.sleep = sleep
        self.limit = limit
        self.reasksStale = reasksStale
    }

    /// Starts one walk unless one is already in flight, and clears the last
    /// failure — asking again after a failure is a fresh attempt, not a
    /// continuation of the failed one.
    func start() {
        lock.lock()
        guard !walking, !reasking else { lock.unlock(); return }
        walking = true
        pendingFailure = nil
        let myEpoch = epoch
        lock.unlock()

        // Copied out to locals rather than read through `self` inside the
        // walk: `fetch`/`map`/`sleep` are plain closures, not references to
        // this feed, so capturing them by value costs nothing and keeps every
        // reference to `self` in the walk below weak — the same discipline
        // `loadSongsFromBridge` uses, and for the same reason: a feed nobody
        // holds any more must be able to deallocate, which stops its walk at
        // its next page rather than running it to completion regardless.
        let fetch = self.fetch
        let map = self.map
        let sleep = self.sleep
        let limit = self.limit
        var replacedThisAttempt = false
        var sawFlagged = false   // any page of this attempt said stale/refreshing

        let workers = self.workers
        workers.enter()
        Thread.detachNewThread { [weak self] in
            defer { workers.leave() }
            let error = walkLibraryPages(fetch: fetch, limit: limit, onPage: { [weak self] page in
                guard let self else { return false }   // feed gone -> stop the walk
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.epoch == myEpoch else { return false }   // reset since -> stop
                let rows = page.rows.map(map)
                if LibraryReask.flagged(page) { sawFlagged = true }
                let firstPage = !replacedThisAttempt
                if replacedThisAttempt {
                    self.pendingAppend.append(contentsOf: rows)
                } else {
                    self.pendingReplace = rows
                    self.pendingReasked = false   // a walk's own first page, not a re-ask's
                    self.pendingAppend = []
                    replacedThisAttempt = true
                }
                if let total = page.total { self.pendingTotal = total }
                self.pendingSkippedVideos = page.skippedVideos
                if firstPage { self.pendingListRev = page.listRev }
                else if page.listRev != self.pendingListRev { self.pendingListRev = nil }
                self.pendingWarming = false
                return true
            }, onRestart: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.epoch == myEpoch else { return }
                // A generation restart discards this attempt's own rows too —
                // slice 1's rule: what's on screen stays until the RESTARTED
                // attempt's first page lands, never blended with it.
                replacedThisAttempt = false
                sawFlagged = false
                self.pendingReplace = nil
                self.pendingAppend = []
                self.pendingTotal = nil
                self.pendingSkippedVideos = nil
                self.pendingListRev = nil
            }, onWarming: { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.epoch == myEpoch else { return }
                self.pendingWarming = true
            }, sleep: sleep)

            guard let self else { return }
            self.lock.lock()
            // Epoch checked BEFORE touching `walking`, and this is the only
            // line in this function that may clear it. A walk `reset()`
            // abandoned must never clear `walking` for whichever walk
            // started AFTER it: `reset()` itself already cleared `walking`
            // once, to hand off exactly that permission. Clearing it
            // unconditionally here (the single-flight race Codex's review
            // caught) let an abandoned walk that finished LATE stomp a
            // second walk's `walking = true`, so a third `start()` launched
            // a third walk concurrent with the second — two walks writing
            // the same generation's `pending*` fields at once, duplicating
            // or corrupting the list.
            guard self.epoch == myEpoch else { self.lock.unlock(); return }   // reset since -> the ending is dropped too
            self.walking = false
            self.pendingWarming = false   // over, one way or the other
            if let error {
                self.pendingFailure = error.errorDescription ?? "SpanDAC couldn't read your library"
            } else {
                self.pendingDone = true
            }
            // A clean walk of a snapshot SpanDAC called stale: what it returned
            // stays on screen and this same thread asks again until a read
            // comes back unflagged. `reasking` is set under the lock that
            // cleared `walking`, so no `start()` can slip between the two.
            let reask = self.reasksStale && error == nil && sawFlagged
            if reask { self.reasking = true }
            self.lock.unlock()
            guard reask else { return }

            self.reask(myEpoch: myEpoch, fetch: fetch, map: map, sleep: sleep, limit: limit)
        }
    }

    /// The re-ask loop (`LibraryReask`), run on the walk's own thread after a
    /// flagged walk. A probe is one page; only an unflagged probe earns the
    /// full re-walk, which is buffered and posted as ONE replacement so the list
    /// swaps wholesale rather than shrinking to a first page and growing back.
    /// Every step re-checks the epoch, so a result that outlived a `reset()` is
    /// dropped like any other background post.
    private func reask(myEpoch: Int,
                       fetch: @escaping (String?, Int) throws -> MusicPage,
                       map: @escaping (MusicRow) -> Row,
                       sleep: (TimeInterval) -> Void,
                       limit: Int) {
        LibraryReask.run(
            sleep: sleep,
            isCurrent: { [weak self] in self?.currentEpochMatches(myEpoch) ?? false },
            probe: { try fetch(nil, limit) },
            rewalk: {
                // A read that did not post (failed, or superseded) ends the re-ask.
                if case .posted(let flagged) = Self.rewalkAndPost(owner: { [weak self] in self }, myEpoch: myEpoch,
                                                                  fetch: fetch, map: map, sleep: sleep, limit: limit) {
                    return flagged
                }
                return false
            })
        lock.lock()
        if epoch == myEpoch { reasking = false }
        lock.unlock()
    }

    /// Reads the whole list again, buffered, and posts it as ONE replacement
    /// flagged `reasked` (the same list read again, so the scene follows its
    /// selection by row id). Says whether it posted, and if so whether the read
    /// was itself flagged (the caller should keep asking). A failed or superseded
    /// read posts nothing and leaves the list as it was.
    ///
    /// Static, with the feed reached through `owner` (a weak capture), so the walk
    /// holds no strong reference to the feed: one nobody holds any more
    /// deallocates and the walk stops at its next page.
    private static func rewalkAndPost(owner: () -> BridgeListFeed<Row>?,
                                      myEpoch: Int,
                                      fetch: (String?, Int) throws -> MusicPage,
                                      map: (MusicRow) -> Row,
                                      sleep: (TimeInterval) -> Void,
                                      limit: Int) -> RewalkResult {
        // `walkLibraryPages` reads page 1 before its epoch check, so a
        // reset that outlived the probe is caught here instead.
        guard owner()?.currentEpochMatches(myEpoch) ?? false else { return .dropped }
        var rows: [Row] = []
        var total: Int? = nil
        var skipped: Int? = nil
        var listRev: String? = nil
        var firstPage = true
        var flagged = false
        var superseded = false
        let error = walkLibraryPages(fetch: fetch, limit: limit, onPage: { page in
            guard owner()?.currentEpochMatches(myEpoch) ?? false else { superseded = true; return false }
            rows.append(contentsOf: page.rows.map(map))
            if LibraryReask.flagged(page) { flagged = true }
            if let t = page.total { total = t }
            skipped = page.skippedVideos
            if firstPage { listRev = page.listRev } else if page.listRev != listRev { listRev = nil }
            firstPage = false
            return true
        }, onRestart: {
            rows = []; total = nil; skipped = nil; listRev = nil; firstPage = true; flagged = false
        }, sleep: sleep)
        // A failed re-read leaves the list as it was, and ends the re-ask.
        guard !superseded, let feed = owner() else { return .dropped }
        feed.lock.lock()
        defer { feed.lock.unlock() }
        guard feed.epoch == myEpoch else { return .dropped }
        guard error == nil else { return .failed }
        feed.pendingReplace = rows
        feed.pendingAppend = []
        feed.pendingTotal = total
        feed.pendingSkippedVideos = skipped
        feed.pendingListRev = listRev
        feed.pendingReasked = true
        return .posted(flagged: flagged)   // still flagged: keep asking, within the same bound
    }

    private enum RewalkResult {
        /// The replacement is posted; `flagged` says the read itself was stale/refreshing.
        case posted(flagged: Bool)
        /// The read failed; the list is as it was.
        case failed
        /// A `reset()` (or the feed's end) got there first; nothing to say to anyone.
        case dropped
    }

    /// How a rebuild the list is waiting on stands (the caller's reading of
    /// SpanDAC's completion fact). The feed only tells `pending` from the rest:
    /// any other verdict is final, and the list is read once more after it.
    enum RefreshProgress: Equatable {
        case pending
        case installed
        /// The rebuild failed or was cancelled.
        case failed
        /// A different SpanDAC process answered: it restarted.
        case restarted
        /// A follow-up ask was declined.
        case deferred
    }

    /// What `refresh` did with the ask.
    enum RefreshClaim: Equatable {
        /// A refresh began.
        case started
        /// A refresh began, and ended the plain re-ask that was running.
        case tookOver
        /// A refresh is already in flight; nothing was started.
        case alreadyRefreshing
        /// The list's own walk is still running; nothing was started.
        case busy
    }

    /// How a `refresh` ended, for the caller to tell the person. Never delivered
    /// for a refresh a `reset()` outlived.
    enum RefreshEnd: Equatable {
        /// No completion fact was awaited: the list was read again, and any
        /// stale-snapshot re-ask it earned has run its course.
        case listOnly
        /// The awaited rebuild reached a final verdict (anything but `pending`)
        /// and the list was read again after that was seen.
        case settled(RefreshProgress)
        /// The awaited rebuild did not report within `LibraryReask`'s bound.
        case boundSpent
        /// The list itself could not be read; it stays as it was.
        case readFailed
    }

    /// A person-asked re-read of a list that is already showing.
    ///
    /// **Claiming.** Nothing starts (`busy`) while the list's own walk is running.
    /// A refresh already in flight is single-flight (`alreadyRefreshing`): a
    /// repeated ask never stacks a second one. A PLAIN stale-snapshot re-ask in
    /// flight is taken over (`tookOver`): that re-ask is waiting on a drain that
    /// began before this ask, so it must not be the one the person waits behind.
    /// The takeover bumps the epoch, so every later post and the ending of the old
    /// worker are dropped (it stops at its next epoch check, posting nothing), and
    /// the rows already drained stay on screen. Exactly one worker posts rows.
    ///
    /// `begin` runs first on the worker (the place to tell SpanDAC to rebuild).
    /// It returns the check for the rebuild's completion, or nil when there is
    /// none to wait for. Then the list is read again in full, buffered, and
    /// posted as ONE `reasked` replacement: the rows on screen stay until it
    /// lands, and the scene keeps its selection by row id.
    ///
    /// What follows is `LibraryReask`'s loop on its own interval and bound, not a
    /// second one. While the last read was flagged stale/refreshing it probes one
    /// page and re-reads when the probe comes back clean; while a check is
    /// supplied it also asks the check each interval. The check is asked BEFORE
    /// each full read, so a verdict of installed/failed means the read that
    /// follows it came after the rebuild ended. A settled verdict re-reads once
    /// and ends; with no check the loop ends when a read comes back unflagged.
    /// `end` is told how it went (not if a `reset()` got there first).
    ///
    /// It holds `reasking` for its whole life, so `start()` stays off exactly as
    /// it does during a re-ask, and `reset()` revokes it like any other worker.
    ///
    /// `end` and `alreadyRefreshing` both run under the feed's lock, so the status
    /// line follows the claim: a refresh's ending lands before the claim is
    /// released, so neither a second `r`'s "already refreshing" nor the next
    /// refresh's own lines can be covered by it, or cover it. Both must only post
    /// (take no lock of this feed's and call nothing back into it).
    @discardableResult
    func refresh(begin: @escaping () -> (() -> RefreshProgress)? = { nil },
                 end: @escaping (RefreshEnd) -> Void = { _ in },
                 alreadyRefreshing: () -> Void = {}) -> RefreshClaim {
        lock.lock()
        guard !walking else { lock.unlock(); return .busy }
        var claim = RefreshClaim.started
        if reasking {
            guard !refreshing else {
                alreadyRefreshing()
                lock.unlock()
                afterAlreadyRefreshingForTest?()
                return .alreadyRefreshing
            }
            epoch += 1   // the old re-ask's every post and its ending are now dropped
            claim = .tookOver
        }
        reasking = true
        refreshing = true
        let myEpoch = epoch
        lock.unlock()

        let fetch = self.fetch
        let map = self.map
        let sleep = self.sleep
        let limit = self.limit

        let workers = self.workers
        workers.enter()
        afterClaimForTest?()
        Thread.detachNewThread { [weak self] in
            defer { workers.leave() }
            // A `reset()` that landed between the claim and this thread starting
            // revoked the refresh: it sends nothing and says nothing.
            guard self?.currentEpochMatches(myEpoch) ?? false else { return }
            let check = begin()
            // Weak all the way down: a feed nobody holds deallocates, and this stops.
            let current: () -> Bool = { self?.currentEpochMatches(myEpoch) ?? false }
            func reread() -> RewalkResult {
                Self.rewalkAndPost(owner: { [weak self] in self }, myEpoch: myEpoch,
                                   fetch: fetch, map: map, sleep: sleep, limit: limit)
            }
            let ended: RefreshEnd? = {
                var verdict = check?() ?? .pending
                var lastFlagged: Bool
                switch reread() {
                case .dropped: return nil
                case .failed: return .readFailed
                case .posted(let flagged): lastFlagged = flagged
                }
                var waited: TimeInterval = 0
                while true {
                    if check != nil, verdict != .pending { return .settled(verdict) }
                    guard lastFlagged || check != nil else { return .listOnly }
                    guard waited < LibraryReask.maxTotalWait else { return check != nil ? .boundSpent : .listOnly }
                    sleep(LibraryReask.interval)
                    waited += LibraryReask.interval
                    guard current() else { return nil }
                    verdict = check?() ?? .pending
                    var reads = verdict != .pending
                    if !reads && lastFlagged {
                        guard let page = try? fetch(nil, limit) else { return .readFailed }
                        reads = !LibraryReask.flagged(page)
                    }
                    guard reads else { continue }
                    guard current() else { return nil }
                    switch reread() {
                    case .dropped: return nil
                    case .failed: return .readFailed
                    case .posted(let flagged): lastFlagged = flagged
                    }
                }
            }()
            guard let self else { return }
            // `end` runs before the claim is released, so a refresh the next `r`
            // starts can only speak after this one's ending, never under it.
            self.lock.lock()
            let still = self.epoch == myEpoch
            if still {
                if let ended { end(ended) }
                self.reasking = false; self.refreshing = false
            }
            self.lock.unlock()
            self.afterRefreshReleasedForTest?()
        }
        return claim
    }

    /// Test-only: runs on the caller's thread after `refresh` has claimed the feed
    /// and before its worker starts, the one point a `reset()` can land in.
    var afterClaimForTest: (() -> Void)?

    /// Test-only: runs on the caller's thread after an `alreadyRefreshing` claim has
    /// released the lock, the point where the running refresh can end and post.
    var afterAlreadyRefreshingForTest: (() -> Void)?

    /// Test-only: runs on a refresh's worker after it has released its claim, the
    /// point where the next `r` can start a new refresh.
    var afterRefreshReleasedForTest: (() -> Void)?

    private func currentEpochMatches(_ e: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == e
    }

    /// Bumps the epoch, so every later post from any walk already running is
    /// dropped and that walk stops at its next page/restart/warming check or
    /// ending. Also clears whatever this feed had drained-but-unconsumed: a
    /// reset discards the list this feed feeds.
    func reset() {
        lock.lock()
        epoch += 1
        walking = false
        reasking = false
        refreshing = false
        pendingReplace = nil
        pendingAppend = []
        pendingTotal = nil
        pendingFailure = nil
        pendingWarming = false
        pendingDone = false
        pendingSkippedVideos = nil
        pendingListRev = nil
        pendingReasked = false
        lock.unlock()
    }

    /// Hands the scene everything landed since the last drain, and clears the
    /// one-shot parts (replace/append/done). `total`, `warming` and `failure`
    /// are level state — read, not cleared — so a tick that lands nothing new
    /// still sees the current total, warming flag and failure sentence.
    ///
    /// **`failure` must be level state, not one-shot.** The scene syncs its
    /// own `bridgeAlbumsFailure`/`bridgeArtistsFailure` to whatever this
    /// returns (`if stored != drained.failure { stored = drained.failure }`),
    /// the same pattern Songs' `bridgeFailurePending` already uses. Clearing
    /// `pendingFailure` here made the tick immediately AFTER the one that
    /// reported a failure see `failure: nil` and overwrite the scene's own
    /// failure back to nil — the give-up message flashed for exactly one
    /// tick and then silently reverted to "Loading…" (caught by
    /// `BridgeLibraryListsSceneTests.testWarmingShowsPreparingAndGivesUpVisibly`).
    /// `start()` and `reset()` are what clear it, by starting a fresh attempt.
    func drain() -> Drained {
        lock.lock()
        let out = Drained(replace: pendingReplace, append: pendingAppend, total: pendingTotal,
                          failure: pendingFailure, warming: pendingWarming, done: pendingDone,
                          skippedVideos: pendingSkippedVideos, listRev: pendingListRev,
                          reasked: pendingReasked)
        pendingReasked = false
        pendingReplace = nil
        pendingAppend = []
        pendingDone = false
        lock.unlock()
        return out
    }
}

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
    /// Opt-in. Only the four top-level lists (Playlists, Songs, Albums,
    /// Artists) ask again when SpanDAC says its snapshot is stale: a list with a
    /// cursor inside it (a drilled-in tracks pane) must never be swapped for a
    /// different length under that cursor, so it keeps the default of off.
    private let reasksStale: Bool

    private var walking = false
    /// A stale-snapshot re-ask is waiting or running (see `LibraryReask`). It
    /// holds `start()` off exactly as `walking` does — one re-ask in flight per
    /// list, never a second beside it — and is cleared by the re-ask's own end
    /// (epoch-checked, like `walking`) or by `reset()`.
    private var reasking = false
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

        Thread.detachNewThread { [weak self] in
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
            rewalk: { [weak self] in
                var rows: [Row] = []
                var total: Int? = nil
                var skipped: Int? = nil
                var listRev: String? = nil
                var firstPage = true
                var flagged = false
                var superseded = false
                let error = walkLibraryPages(fetch: fetch, limit: limit, onPage: { page in
                    guard self?.currentEpochMatches(myEpoch) ?? false else { superseded = true; return false }
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
                guard let self, !superseded, error == nil else { return false }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.epoch == myEpoch else { return false }
                self.pendingReplace = rows
                self.pendingAppend = []
                self.pendingTotal = total
                self.pendingSkippedVideos = skipped
                self.pendingListRev = listRev
                self.pendingReasked = true
                return flagged   // still flagged: keep asking, within the same bound
            })
        lock.lock()
        if epoch == myEpoch { reasking = false }
        lock.unlock()
    }

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

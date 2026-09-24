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

    private var walking = false
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

    init(fetch: @escaping (String?, Int) throws -> MusicPage,
        map: @escaping (MusicRow) -> Row,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        limit: Int = 100) {
        self.fetch = fetch
        self.map = map
        self.sleep = sleep
        self.limit = limit
    }

    /// Starts one walk unless one is already in flight, and clears the last
    /// failure — asking again after a failure is a fresh attempt, not a
    /// continuation of the failed one.
    func start() {
        lock.lock()
        guard !walking else { lock.unlock(); return }
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

        Thread.detachNewThread { [weak self] in
            let error = walkLibraryPages(fetch: fetch, limit: limit, onPage: { [weak self] page in
                guard let self else { return false }   // feed gone -> stop the walk
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.epoch == myEpoch else { return false }   // reset since -> stop
                let rows = page.rows.map(map)
                if replacedThisAttempt {
                    self.pendingAppend.append(contentsOf: rows)
                } else {
                    self.pendingReplace = rows
                    self.pendingAppend = []
                    replacedThisAttempt = true
                }
                if let total = page.total { self.pendingTotal = total }
                self.pendingSkippedVideos = page.skippedVideos
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
                self.pendingReplace = nil
                self.pendingAppend = []
                self.pendingTotal = nil
                self.pendingSkippedVideos = nil
            }, onWarming: { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.epoch == myEpoch else { return }
                self.pendingWarming = true
            }, sleep: sleep)

            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
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
            guard self.epoch == myEpoch else { return }   // reset since -> the ending is dropped too
            self.walking = false
            self.pendingWarming = false   // over, one way or the other
            if let error {
                self.pendingFailure = error.errorDescription ?? "Bridge couldn't read your library"
            } else {
                self.pendingDone = true
            }
        }
    }

    /// Bumps the epoch, so every later post from any walk already running is
    /// dropped and that walk stops at its next page/restart/warming check or
    /// ending. Also clears whatever this feed had drained-but-unconsumed: a
    /// reset discards the list this feed feeds.
    func reset() {
        lock.lock()
        epoch += 1
        walking = false
        pendingReplace = nil
        pendingAppend = []
        pendingTotal = nil
        pendingFailure = nil
        pendingWarming = false
        pendingDone = false
        pendingSkippedVideos = nil
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
                          skippedVideos: pendingSkippedVideos)
        pendingReplace = nil
        pendingAppend = []
        pendingDone = false
        lock.unlock()
        return out
    }
}

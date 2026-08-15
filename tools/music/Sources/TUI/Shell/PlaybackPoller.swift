// tools/music/Sources/TUI/Shell/PlaybackPoller.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Background thread that polls Apple Music on its own cadence and publishes
/// snapshots to a NowPlayingStore. Decouples poll latency (~50-500ms per
/// AppleScript call) from the main loop's input/redraw latency, so the live
/// now-playing bar advances while the user is idle and input never freezes
/// waiting on a poll.
///
/// Threading contract: `running` and `desiredArtSize` are the only fields
/// touched from two threads; both are guarded by `lock`. The poll cadence is
/// `intervalMs`. On `stop()` the loop exits after its current iteration and
/// signals `finished`; `stop()` waits briefly so the main loop can leave raw
/// mode after the poller is idle.
final class PlaybackPoller {
    private let store: NowPlayingStore
    private let backend: AppleScriptBackend
    private let appQueue: AppQueueStore
    private let queueStore: QueueStore
    private let intervalMs: UInt32
    private let lock = NSLock()
    private var running = false
    // Render-published desired art LINES size (cols, rows) — see
    // setDesiredArtSize(). Cross-thread like `running`: NowPlayingScene
    // writes it once per render (main thread), tick() reads it once per poll
    // (poller thread). Default matches the pre-B1 fixed extraction size.
    private var desiredArtSize: (cols: Int, rows: Int) = (44, 22)
    private let finished = DispatchSemaphore(value: 0)

    // Thread-confined working state (poller thread only).
    // Queue-resume SAVE: the last AppQueue actually written to queue.json (or
    // nil if nothing's been written this session). Compared each tick against
    // appQueue.read() to decide whether to write — see syncQueuePersistence().
    private var lastWrittenQueue: AppQueue? = nil
    private var lastTrack = ""
    private var lastArtist = ""
    private var lastPosition = 0
    private var lastDuration = 0
    private var stoppedPolls = 0
    private var advanceGate = AdvanceRetryGate()
    private var history: [(track: String, artist: String)] = []
    private var surrounding: [TrackListEntry] = []
    private var contextName = ""
    private var artLines: [String] = []
    // Raw temp-file path backing `artLines` (extractArtwork()'s fixed path),
    // kept alongside it for the Now tab's kitty-graphics path — set/cleared at
    // the same sites as artLines, nil whenever artLines is genuinely empty.
    private var artPath: String? = nil
    // The sizedArtKey `artLines` was last set for — the mid-track branch
    // compares against it so a resize BACK to an already-cached size adopts
    // that size's rendering instead of pinning the previous one (a bare
    // cache-miss check can't see that case: the cache hits, nothing resolves,
    // and stale lines survive to the next track).
    private var artLinesKey = ""
    private var lastContext: ContextQueue? = nil
    private var qEnded = false
    private var endedPlaylist = ""
    private var endedTrack = ""
    private var endedArtist = ""
    private var endedArtLines: [String] = []
    // Rendered art per album|artist. Consecutive tracks of the same album skip
    // the extract+chafa round-trip entirely; empty results are cached too so an
    // artless album isn't re-extracted on every track change.
    private var artCache: [String: [String]] = [:]
    // Raw-bytes temp path per album|artist, parallel to artCache — a lines
    // cache HIT must still resolve to the CORRECT album's raw file for the
    // kitty path, not whatever a single shared filename last happened to
    // hold (that was the wrong-album-pinned-forever bug: revisiting an
    // already-cached album skipped extraction entirely, so the kitty path
    // read stale bytes left over from a totally different album). Absent key
    // means "no artwork for this album" (extraction returned nil), same
    // meaning as an empty artCache entry.
    private var artPathCache: [String: String] = [:]
    // Per-album (nowAlbumKey) marker: this album has been extracted at least
    // once, whatever the outcome. Lets a sized-lines cache miss on an artless
    // album (no artPathCache entry) be recognized as "already tried, still no
    // artwork" WITHOUT re-running AppleScript extraction — a resize should
    // only ever re-render lines from bytes already on disk, never re-extract.
    private var artExtracted: Set<String> = []

    /// Deterministic per-album temp path so two different albums never share
    /// (and one can never silently overwrite the other's) raw art bytes.
    /// Hex-hashed rather than sanitized-verbatim to avoid collisions between
    /// album/artist pairs that differ only in punctuation. Internal (not
    /// `private`) so it's directly unit-testable — pure, no I/O.
    func tempArtPath(for artKey: String) -> String {
        "/tmp/music-now-art-\(String(format: "%08x", kittyImageID(forKey: artKey))).dat"
    }

    /// Lines-cache key: `nowAlbumKey` (album|artist) plus the requested size,
    /// so a cache hit only fires when both the album AND the exact requested
    /// size match — a resize re-keys instead of reusing a mismatched size's
    /// pre-rendered text. `artPathCache` stays keyed by `nowAlbumKey` alone
    /// (raw bytes don't vary with size). Pure.
    func sizedArtKey(album: String, artist: String, cols: Int, rows: Int) -> String {
        "\(nowAlbumKey(album: album, artist: artist))\u{0}\(cols)x\(rows)"
    }

    /// Delete every per-album art temp file this poller has written this
    /// session. Called on graceful TUI exit (see Shell.swift) so /tmp doesn't
    /// accumulate one file per distinct album played over a long session —
    /// and also whenever the 64-entry cache flushes below, so a very long
    /// session doesn't leak files for albums that have already been evicted
    /// from artPathCache. Safe to call from the main thread once the poller
    /// thread is confirmed stopped (stop() has returned).
    func cleanupArtFiles() {
        for path in artPathCache.values {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// The one place a sizedKey lands in `artCache` — flushes all three art
    /// structures (plus their backing temp files) once `artCache` passes 64
    /// entries, the same threshold and flush that used to guard a single
    /// insert site before sizing split it into three call sites (re-render,
    /// artless marker, full extraction).
    private func insertArtCache(sizedKey: String, lines: [String]) {
        if artCache.count > 64 {
            cleanupArtFiles()
            artCache.removeAll()
            artPathCache.removeAll()
            artExtracted.removeAll()
        }
        artCache[sizedKey] = lines
    }

    /// The sized-lines cache MISS resolution, shared by both callers in
    /// tick(): the track-change branch (called after the context fetch, once
    /// a miss on the new track's sizedKey is already known) and the
    /// mid-track resize check (called only when a resize freshly misses the
    /// cache for the CURRENT track's album). Same album, same size, same
    /// three-way decision either way, so a resize gets identical treatment
    /// whether it lands on a track boundary or mid-track. Updates
    /// `artLines`/`artPath` in place; does not touch `store` — the caller's
    /// existing `store.write` publishes the result.
    private func resolveArt(artKey: String, sizedKey: String, cols: Int, rows: Int) {
        if let rawPath = artPathCache[artKey] {
            // Raw bytes already on disk from a prior extraction (this album,
            // a different size) — re-render lines at the new size ONLY. No
            // AppleScript round-trip.
            let lines = artworkToAscii(path: rawPath, width: cols, height: rows)
            artLines = lines
            artPath = rawPath
            insertArtCache(sizedKey: sizedKey, lines: lines)
        } else if artExtracted.contains(artKey) {
            // Already extracted this album once and found no artwork — that
            // answer doesn't change with size, so don't re-run AppleScript
            // to learn it again.
            artLines = []
            artPath = nil
            insertArtCache(sizedKey: sizedKey, lines: [])
        } else {
            // First sight of this album: the full extract+render round-trip,
            // at the currently published size. Reachable mid-track only if
            // the track-change branch somehow never extracted (shouldn't
            // happen — harmless if it does).
            let extracted = currentTrackArtLines(width: cols, height: rows, path: tempArtPath(for: artKey))
            artLines = extracted.lines
            artPath = extracted.path
            artExtracted.insert(artKey)
            insertArtCache(sizedKey: sizedKey, lines: artLines)
            artPathCache[artKey] = extracted.path
        }
    }

    init(store: NowPlayingStore, backend: AppleScriptBackend, appQueue: AppQueueStore,
         queueStore: QueueStore = QueueStore(), intervalMs: UInt32 = 1000) {
        self.store = store
        self.backend = backend
        self.appQueue = appQueue
        self.queueStore = queueStore
        self.intervalMs = intervalMs
    }

    func start() {
        lock.lock(); running = true; lock.unlock()
        let thread = Thread { [weak self] in self?.loop() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Signal the loop to stop and wait (bounded) for it to finish its current
    /// tick. Safe to call from the main thread before exitRawMode().
    func stop() {
        lock.lock(); running = false; lock.unlock()
        _ = finished.wait(timeout: .now() + 2.0)
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Called from the render thread (NowPlayingScene) once per frame while
    /// art is shown. Clamped here too, not just at the call site — a size
    /// this poller was never designed to extract at should be impossible to
    /// reach regardless of what the caller passes. Floor matches
    /// NowPlayingScene's own clampedArtSize (20, 10). Idempotent sets are
    /// fine: this is two Ints under a lock at render cadence.
    func setDesiredArtSize(cols: Int, rows: Int) {
        let clamped = (cols: max(20, cols), rows: max(10, rows))
        lock.lock(); desiredArtSize = clamped; lock.unlock()
    }

    /// Poller-thread read of the render-published size. Holds `lock` only to
    /// copy the tuple — never across extraction.
    private func readDesiredArtSize() -> (cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        return desiredArtSize
    }

    private func loop() {
        while isRunning() {
            tick()
            // Sleep in small slices so stop() is responsive even with a long interval.
            var slept: UInt32 = 0
            while slept < intervalMs, isRunning() {
                usleep(50 * 1000)
                slept += 50
            }
        }
        finished.signal()
    }

    /// The current working state as a publishable snapshot.
    private func snapshot(outcome: PollOutcome) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            outcome: outcome, history: history, surrounding: surrounding,
            contextName: contextName, artLines: artLines, artPath: artPath,
            queueEnded: qEnded, endedPlaylist: endedPlaylist,
            endedTrack: endedTrack, endedArtist: endedArtist, endedArtLines: endedArtLines)
    }

    /// Queue-resume SAVE, the one choke point:
    /// every mutation to the app-owned queue — this poller's own auto-advance
    /// below AND next/prev/jump/select from the main loop, which the poller
    /// only ever observes via `appQueue.read()` on its next tick — flows
    /// through here. Called via `defer` at the top of `tick()`, so it runs
    /// after that tick's queue/advance logic on every exit path, including
    /// early returns.
    private func syncQueuePersistence() {
        let active = appQueue.read()
        if queueShouldSave(active: active, lastWritten: lastWrittenQueue) {
            guard let active, active.currentIndex >= 1, active.currentIndex <= active.tracks.count else {
                // Malformed queue (shouldn't happen) — remember it so this
                // isn't retried every tick, but never write garbage to disk.
                lastWrittenQueue = active
                return
            }
            // The one extra AppleScript read this feature costs, and only at
            // save time — never per poll tick. Failure-tolerant (nil anchor
            // on the macOS 26 -1728 bug); name+artist below always saves.
            let anchorID = currentTrackPersistentID(backend: backend)
            let current = active.tracks[active.currentIndex - 1]
            let persisted = PersistedQueue(queue: active, anchorPersistentID: anchorID,
                                            anchorName: current.name, anchorArtist: current.artist)
            try? queueStore.save(persisted)
            lastWrittenQueue = active
        } else if queueShouldClear(active: active, lastWritten: lastWrittenQueue) {
            // Queue went native/stopped — never let a stale queue linger.
            queueStore.clear()
            lastWrittenQueue = nil
        }
    }

    func tick() {
        defer { syncQueuePersistence() }
        switch pollNowPlaying(backend: backend) {
        case .active(let np):
            stoppedPolls = 0
            let priorPos = lastPosition          // last-seen position of the PREVIOUS track
            let priorDur = lastDuration
            lastPosition = np.position
            lastDuration = np.duration
            if np.track != lastTrack {
                // Capture everything about the track we're leaving, before overwrite.
                let prevArt = artLines           // ended track's art (not yet re-extracted)
                let prevCtx = lastContext
                let prevTrack = lastTrack
                let prevArtist = lastArtist
                let prevNatural = priorDur > 0 && priorPos >= priorDur - 8

                if !prevTrack.isEmpty {
                    if history.first.map({ $0.track != prevTrack || $0.artist != prevArtist }) ?? true {
                        history.insert((track: prevTrack, artist: prevArtist), at: 0)
                        if history.count > 20 { history.removeLast() }
                    }
                }
                lastTrack = np.track
                lastArtist = np.artist

                // Publish the new track's metadata immediately — with cached art
                // when the album+size is known, blank otherwise — so the UI
                // reflects the change within one poll cycle instead of waiting
                // on the context fetch + artwork resolution below (the slow
                // chain). Size is read once here and reused for the rest of
                // this tick's decision below — a mid-tick resize is not a
                // thing (the read is on the poller thread; the render thread
                // publishes size once per its own frame).
                let artKey = nowAlbumKey(album: np.album, artist: np.artist)
                let size = readDesiredArtSize()
                let sizedKey = sizedArtKey(album: np.album, artist: np.artist, cols: size.cols, rows: size.rows)
                let cachedLines = artCache[sizedKey]
                artLines = cachedLines ?? []
                // Look up THIS album's own temp path — never the leftover
                // value from whatever album was extracted most recently. A
                // sized-lines cache hit means resolution won't run below, so
                // artPathCache must already hold the right answer (set the
                // one time this album was actually extracted, at a path
                // unique to it); a genuine miss (first sight of this album at
                // this size) clears it so the kitty path doesn't show
                // anything while resolution below is still in flight.
                artPath = cachedLines != nil ? artPathCache[artKey] : nil
                store.write(snapshot(outcome: .active(np)))

                // When the app owns the queue (a playlist track was picked), the
                // Up Next window comes from OUR list — Music's `current playlist`
                // is unreliable after the 26.x regression. Otherwise prefer Music's
                // real context (current playlist), falling back to album tracks.
                if let aq = appQueue.read() {
                    let w = appQueueWindow(aq)
                    surrounding = w.tracks
                    contextName = w.name
                    lastContext = nil
                } else {
                    let ctx = pollContextQueue(np: np, backend: backend)
                    if ctx.tracks.isEmpty {
                        surrounding = pollAlbumTracks(for: np, backend: backend)
                        contextName = np.album
                        lastContext = nil
                    } else {
                        surrounding = ctx.tracks
                        contextName = ctx.name
                        lastContext = ctx
                    }
                }
                if cachedLines == nil {
                    resolveArt(artKey: artKey, sizedKey: sizedKey, cols: size.cols, rows: size.rows)
                }
                artLinesKey = sizedKey

                // Queue-end detection: prev playlist's last track ended naturally
                // and we flipped to library autoplay.
                let fired = detectQueueEnd(
                    prevWasRealPlaylist: prevCtx.map { !isLibraryContextName($0.name) && !$0.name.isEmpty } ?? false,
                    prevAtLastTrack: prevCtx.map { $0.total > 0 && $0.currentIndex >= $0.total } ?? false,
                    prevNaturalEnd: prevNatural,
                    nowIsLibraryAutoplay: isLibraryContextName(contextName))
                if fired {
                    qEnded = true
                    endedPlaylist = prevCtx?.name ?? ""
                    endedTrack = prevTrack
                    endedArtist = prevArtist
                    endedArtLines = prevArt
                } else if !isLibraryContextName(contextName) {
                    // Re-entered a real context — clear any prior end-of-queue offer.
                    qEnded = false
                }
            } else {
                // Mid-track: a resize can change the published size even
                // though the album hasn't (track-change above only resolves
                // once, at whatever size was published then). `artLinesKey`
                // says which sized rendering `artLines` currently holds; on
                // any mismatch, adopt the cached rendering when one exists
                // (covers resizing BACK to an already-rendered size — a bare
                // cache-miss check left the previous size's lines pinned) or
                // resolve fresh when it doesn't. Bounds a resize's lag to one
                // poll interval — B2's acceptance criterion. A full extract
                // can only trigger here for a never-extracted album, which
                // shouldn't happen (track-change above already extracted it)
                // — harmless if it somehow does.
                let size = readDesiredArtSize()
                let artKey = nowAlbumKey(album: np.album, artist: np.artist)
                let sizedKey = sizedArtKey(album: np.album, artist: np.artist, cols: size.cols, rows: size.rows)
                if artLinesKey != sizedKey {
                    if let cached = artCache[sizedKey] {
                        artLines = cached
                        artPath = artPathCache[artKey]   // nil for artless albums — correct
                    } else {
                        resolveArt(artKey: artKey, sizedKey: sizedKey, cols: size.cols, rows: size.rows)
                    }
                    artLinesKey = sizedKey
                }
            }
            store.write(snapshot(outcome: .active(np)))

        case .stopped:
            stoppedPolls += 1
            // Auto-advance only when the previous track reached its natural end.
            let naturalEnd = lastDuration > 0 && lastPosition >= max(0, lastDuration - 4)
            // App-owned queue: the single track stopped at its end (Autoplay off) —
            // play the next track ourselves. step() returns nil at the queue's end,
            // where we clear the queue and let playback stay stopped.
            if naturalEnd, appQueue.isActive {
                if let (pl, pos) = appQueue.step(1) {
                    // step(1) commits the index BEFORE the play attempt. If the
                    // play errors and the result is dropped, naturalEnd stays true
                    // next tick and the loop walks the whole remaining queue
                    // silently. Bounded recovery instead: roll the step back and
                    // retry this track up to the gate's cap, then keep the step
                    // (skip past it) so a permanent failure can't spin forever.
                    if playQueueTrack(backend: backend, playlist: pl, position: pos) {
                        advanceGate.playSucceeded()
                    } else if advanceGate.playFailed() == .retry {
                        _ = appQueue.step(-1)
                    }
                    stoppedPolls = 0
                    return // next tick will observe the new track (or retry)
                }
                // Reached the end of the app-owned queue — surface the continuation menu.
                if !qEnded {
                    qEnded = true
                    endedPlaylist = appQueue.read()?.playlistName ?? contextName
                    endedTrack = lastTrack
                    endedArtist = lastArtist
                    endedArtLines = artLines
                }
                appQueue.clear()
            } else if naturalEnd,
               let cur = surrounding.firstIndex(where: { $0.isCurrent }),
               cur + 1 < surrounding.count {
                let entry = surrounding[cur + 1]
                playLibraryTrack(backend: backend, title: entry.name, artist: entry.artist)
                stoppedPolls = 0
                return // next tick will observe the new track
            }
            // End-of-queue on STOP (the common case): the last track of a real
            // playlist finished and playback stopped (no autoplay). This is the
            // reliable queue-end signal — not a context flip to the library.
            if !qEnded,
               lastDuration > 0, lastPosition >= lastDuration - 12,
               let ctx = lastContext,
               !isLibraryContextName(ctx.name), !ctx.name.isEmpty,
               ctx.total > 0, ctx.currentIndex >= ctx.total {
                qEnded = true
                endedPlaylist = ctx.name
                endedTrack = lastTrack
                endedArtist = lastArtist
                endedArtLines = artLines
            }
            // Tolerate a few stopped polls before publishing a genuine stop, so a
            // brief gap between tracks doesn't flash the stopped state. But once a
            // queue-end is detected, publish immediately so the menu appears.
            if !qEnded && !lastTrack.isEmpty && stoppedPolls < 4 { return }
            store.write(snapshot(outcome: .stopped))

        case .unavailable:
            // Transient read failure: keep the last published snapshot. Never blank
            // on a single hiccup (the published snapshot is simply not overwritten).
            return
        }
    }
}

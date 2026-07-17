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
/// Threading contract: `running` is the only field touched from two threads;
/// it is guarded by `lock`. The poll cadence is `intervalMs`. On `stop()` the
/// loop exits after its current iteration and signals `finished`; `stop()`
/// waits briefly so the main loop can leave raw mode after the poller is idle.
final class PlaybackPoller {
    private let store: NowPlayingStore
    private let backend: AppleScriptBackend
    private let appQueue: AppQueueStore
    private let queueStore: QueueStore
    private let intervalMs: UInt32
    private let lock = NSLock()
    private var running = false
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
    private var history: [(track: String, artist: String)] = []
    private var surrounding: [TrackListEntry] = []
    private var contextName = ""
    private var artLines: [String] = []
    // Raw temp-file path backing `artLines` (extractArtwork()'s fixed path),
    // kept alongside it for the Now tab's kitty-graphics path — set/cleared at
    // the same sites as artLines, nil whenever artLines is genuinely empty.
    private var artPath: String? = nil
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

    /// Deterministic per-album temp path so two different albums never share
    /// (and one can never silently overwrite the other's) raw art bytes.
    /// Hex-hashed rather than sanitized-verbatim to avoid collisions between
    /// album/artist pairs that differ only in punctuation. Internal (not
    /// `private`) so it's directly unit-testable — pure, no I/O.
    func tempArtPath(for artKey: String) -> String {
        "/tmp/music-now-art-\(String(format: "%08x", kittyImageID(forKey: artKey))).dat"
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
                // when the album is known, blank otherwise — so the UI reflects
                // the change within one poll cycle instead of waiting on the
                // context fetch + artwork extraction below (the slow chain).
                let artKey = "\(np.album)\u{0}\(np.artist)"
                let cachedArt = artCache[artKey]
                artLines = cachedArt ?? []
                // Look up THIS album's own temp path — never the leftover
                // value from whatever album was extracted most recently. A
                // cache hit means extraction won't run below, so artPathCache
                // must already hold the right answer (set the one time this
                // album was actually extracted, at a path unique to it); a
                // genuine miss (first sight of this album) clears it so the
                // kitty path doesn't show anything while extraction below is
                // still in flight.
                artPath = cachedArt != nil ? artPathCache[artKey] : nil
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
                if cachedArt == nil {
                    let extracted = currentTrackArtLines(width: 44, height: 22, path: tempArtPath(for: artKey))
                    artLines = extracted.lines
                    artPath = extracted.path
                    if artCache.count > 64 {
                        cleanupArtFiles()
                        artCache.removeAll()
                        artPathCache.removeAll()
                    }
                    artCache[artKey] = artLines
                    artPathCache[artKey] = extracted.path
                }

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
                    playQueueTrack(backend: backend, playlist: pl, position: pos)
                    stoppedPolls = 0
                    return // next tick will observe the new track
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

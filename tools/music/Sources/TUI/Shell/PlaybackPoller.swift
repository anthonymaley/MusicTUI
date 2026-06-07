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
    private let intervalMs: UInt32
    private let lock = NSLock()
    private var running = false
    private let finished = DispatchSemaphore(value: 0)

    // Thread-confined working state (poller thread only).
    private var lastTrack = ""
    private var lastArtist = ""
    private var lastPosition = 0
    private var lastDuration = 0
    private var stoppedPolls = 0
    private var history: [(track: String, artist: String)] = []
    private var surrounding: [TrackListEntry] = []
    private var contextName = ""
    private var artLines: [String] = []

    init(store: NowPlayingStore, backend: AppleScriptBackend, intervalMs: UInt32 = 1000) {
        self.store = store
        self.backend = backend
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

    func tick() {
        switch pollNowPlaying(backend: backend) {
        case .active(let np):
            stoppedPolls = 0
            lastPosition = np.position
            lastDuration = np.duration
            if np.track != lastTrack {
                if !lastTrack.isEmpty {
                    if history.first.map({ $0.track != lastTrack || $0.artist != lastArtist }) ?? true {
                        history.insert((track: lastTrack, artist: lastArtist), at: 0)
                        if history.count > 20 { history.removeLast() }
                    }
                }
                lastTrack = np.track
                lastArtist = np.artist
                // Prefer the real playback context (current playlist); fall back to
                // album tracks when there's no playlist context.
                let ctx = pollContextQueue(np: np, backend: backend)
                if ctx.tracks.isEmpty {
                    surrounding = pollAlbumTracks(for: np, backend: backend)
                    contextName = np.album
                } else {
                    surrounding = ctx.tracks
                    contextName = ctx.name
                }
                artLines = currentTrackArtLines(width: 36, height: 18)
            }
            store.write(NowPlayingSnapshot(outcome: .active(np), history: history, surrounding: surrounding, contextName: contextName, artLines: artLines))

        case .stopped:
            stoppedPolls += 1
            // Auto-advance only when the previous track reached its natural end.
            let naturalEnd = lastDuration > 0 && lastPosition >= max(0, lastDuration - 4)
            if naturalEnd,
               let cur = surrounding.firstIndex(where: { $0.isCurrent }),
               cur + 1 < surrounding.count {
                let entry = surrounding[cur + 1]
                playLibraryTrack(backend: backend, title: entry.name, artist: entry.artist)
                stoppedPolls = 0
                return // next tick will observe the new track
            }
            // Tolerate a few stopped polls before publishing a genuine stop, so a
            // brief gap between tracks doesn't flash the stopped state.
            if !lastTrack.isEmpty && stoppedPolls < 4 { return }
            store.write(NowPlayingSnapshot(outcome: .stopped, history: history, surrounding: surrounding, contextName: contextName, artLines: artLines))

        case .unavailable:
            // Transient read failure: keep the last published snapshot. Never blank
            // on a single hiccup (the published snapshot is simply not overwritten).
            return
        }
    }
}

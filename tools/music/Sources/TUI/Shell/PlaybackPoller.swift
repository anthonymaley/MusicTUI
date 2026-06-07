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

    /// Overridden in Task 3 to carry history/album-context/auto-advance.
    func tick() {
        let outcome = pollNowPlaying(backend: backend)
        let prev = store.read()
        store.write(NowPlayingSnapshot(outcome: outcome, history: prev.history, surrounding: prev.surrounding))
    }
}

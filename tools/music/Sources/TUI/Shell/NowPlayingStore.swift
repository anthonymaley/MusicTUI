// tools/music/Sources/TUI/Shell/NowPlayingStore.swift
import Foundation

/// One frame's worth of playback truth, copied atomically between the poller
/// thread and the main render loop. All fields are value types so a read under
/// lock yields an independent, internally-consistent copy.
struct NowPlayingSnapshot {
    var outcome: PollOutcome
    var history: [(track: String, artist: String)]
    var surrounding: [TrackListEntry]      // playback-context window (current playlist/album)
    var contextName: String = ""           // name of the current playlist/album
    var artLines: [String] = []            // current track album art, rendered
}

/// Thread-safe box around the latest snapshot. The poller calls `write`; the
/// main loop calls `read` once per frame. One lock, one struct — the entire
/// shared-mutable-state surface of the shell (see spec: "one poller, one store,
/// one lock").
final class NowPlayingStore {
    private let lock = NSLock()
    private var snapshot = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])

    func read() -> NowPlayingSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func write(_ next: NowPlayingSnapshot) {
        lock.lock(); snapshot = next; lock.unlock()
    }
}

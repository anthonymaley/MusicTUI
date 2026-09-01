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
    var artPath: String? = nil             // current track album art, raw file (kitty path; nil when unset/cleared)
    var queueEnded: Bool = false           // show the continuation card menu
    var endedSource: ContinuationSource? = nil  // what just ended, label and source kept apart
    var endedTrack: String = ""            // last context track title (seed for Radio/Similar)
    var endedArtist: String = ""           // last context track artist
    var endedArtLines: [String] = []       // last context track album art (captured at detection)
}

/// Thread-safe box around the latest snapshot. The poller calls `write`; the
/// main loop calls `read` once per frame. One lock, one struct — the entire
/// shared-mutable-state surface of the shell (see spec: "one poller, one store,
/// one lock").
final class NowPlayingStore {
    private let lock = NSLock()
    private var snapshot = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])
    private var generation = 0

    func read() -> NowPlayingSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Snapshot plus a counter that bumps on every write. The render loop skips
    /// repainting when the generation hasn't moved (and no key/resize arrived),
    /// instead of redrawing the whole screen ~10x/s unconditionally.
    func readWithGeneration() -> (snapshot: NowPlayingSnapshot, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        return (snapshot, generation)
    }

    func write(_ next: NowPlayingSnapshot) {
        lock.lock(); snapshot = next; generation += 1; lock.unlock()
    }
}

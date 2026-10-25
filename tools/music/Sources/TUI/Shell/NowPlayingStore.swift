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
    /// Bridge's own state while Bridge is selected. **nil means Music.app mode**,
    /// and the Music.app path never sets it, so a nil here is also the promise
    /// that the Now tab renders exactly as it did before Bridge existed.
    var bridge: BridgeNow? = nil
    /// The `queue_token` of the play whose rows `surrounding` draws, while Bridge
    /// is selected and those rows are vouched for by the status. Nil when no rows
    /// are shown, or the play recorded no token (an older SpanDAC): Enter on an
    /// Up Next row has nothing to name then, and does not send.
    var spanDACQueueToken: String? = nil
}

extension NowPlayingSnapshot: Equatable {
    /// Field-wise, by hand: `history` is an array of tuples, which cannot be
    /// synthesised. Two snapshots that compare equal draw identically.
    static func == (a: NowPlayingSnapshot, b: NowPlayingSnapshot) -> Bool {
        a.outcome == b.outcome
            && a.history.elementsEqual(b.history, by: { $0.track == $1.track && $0.artist == $1.artist })
            && a.surrounding == b.surrounding
            && a.contextName == b.contextName
            && a.artLines == b.artLines
            && a.artPath == b.artPath
            && a.queueEnded == b.queueEnded
            && a.endedSource == b.endedSource
            && a.endedTrack == b.endedTrack
            && a.endedArtist == b.endedArtist
            && a.endedArtLines == b.endedArtLines
            && a.bridge == b.bridge
            && a.spanDACQueueToken == b.spanDACQueueToken
    }
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

    /// Snapshot plus a counter that bumps when a write CHANGES the snapshot. The
    /// render loop skips repainting when the generation hasn't moved (and no
    /// key/resize arrived), instead of redrawing the whole screen ~10x/s
    /// unconditionally. A write equal to the stored snapshot (paused playback
    /// polled again) is not a change and does not move it.
    func readWithGeneration() -> (snapshot: NowPlayingSnapshot, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        return (snapshot, generation)
    }

    func write(_ next: NowPlayingSnapshot) {
        lock.lock(); defer { lock.unlock() }
        if next == snapshot { return }
        snapshot = next; generation += 1
    }
}

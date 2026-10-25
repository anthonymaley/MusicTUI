// tools/music/Sources/TUI/Shell/ShellRenderGate.swift
import Foundation

/// Whether the shell loop should repaint because of what the poller or the
/// status store did. Key, resize and scene-`tick` repaints are decided by the
/// loop itself; this owns only the two passive sources, so they can be tested
/// without a terminal.
///
/// Why it exists: every body repaint clears and rewrites the whole screen,
/// which is costly over SSH. A paused song polled again, or a playing song's
/// elapsed second while a browsing tab (which draws no progress) is up, changes
/// nothing on screen.
struct ShellRenderGate {
    private var lastGeneration = -1
    private var lastSeen: NowPlayingSnapshot?
    private var lastToast: StatusToast?

    /// Call once per loop pass with the store's latest read. Compares against
    /// the last snapshot SEEN (not last painted), so an elapsed-only change that
    /// was ignored on a browsing tab can never hide a later real change.
    mutating func snapshotNeedsRender(snapshot: NowPlayingSnapshot, generation: Int, active: SceneID) -> Bool {
        guard generation != lastGeneration else { return false }
        lastGeneration = generation
        defer { lastSeen = snapshot }
        guard let previous = lastSeen else { return true }
        if shellSceneShowsProgress(active) { return true }
        return !previous.equalIgnoringElapsed(snapshot)
    }

    /// A toast appearing, changing or expiring repaints the footer.
    mutating func toastNeedsRender(_ toast: StatusToast?) -> Bool {
        guard toast != lastToast else { return false }
        lastToast = toast
        return true
    }
}

/// Scenes whose body draws playback progress / elapsed time. Every other scene
/// ignores `position` when rendering, so a position-only change repaints
/// nothing there. Exhaustive on purpose: a new scene must choose.
func shellSceneShowsProgress(_ id: SceneID) -> Bool {
    switch id {
    case .nowPlaying: return true
    case .playlists, .speakers, .library, .radio, .discover: return false
    case .search, .queue: return true   // no scene ships under these ids; stay conservative
    }
}

extension NowPlayingSnapshot {
    /// Equal once the elapsed position is set aside. Duration, track, state and
    /// everything else must still match.
    func equalIgnoringElapsed(_ other: NowPlayingSnapshot) -> Bool {
        func zeroed(_ s: NowPlayingSnapshot) -> NowPlayingSnapshot {
            var c = s
            if case .active(var np) = c.outcome { np.position = 0; c.outcome = .active(np) }
            return c
        }
        return zeroed(self) == zeroed(other)
    }
}

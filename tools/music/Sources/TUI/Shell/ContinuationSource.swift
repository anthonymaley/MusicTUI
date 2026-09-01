// tools/music/Sources/TUI/Shell/ContinuationSource.swift
//
// What the end-of-queue continuation menu is allowed to offer, modelled so the
// two meanings cannot be conflated by accident.
//
// `AppQueue` already carries both (`playlistName` addresses, `displayName`
// labels) but they are both `String`, so a caller that reaches for the wrong
// one compiles cleanly. That is exactly what happened: the poller wrote
// `playlistName` into the continuation state, so an album that had just ended
// offered "Shuffle Library" and, on press, shuffled the whole 14k library.
//
// This is the same shape as the v2-lite index rule: `currentIndex` (play-order
// position) and `currentSourcePosition` (what `play track N of playlist X`
// consumes) are both Ints and must never be swapped.

import Foundation

/// Where a continuation action gets its music.
///
/// Routing is decided by the SOURCE's addressability, never by whether a label
/// happens to be set: a label is presentation metadata and must not steer
/// playback.
enum ContinuationSource: Equatable {
    /// A real, AppleScript-addressable playlist. Label and source coincide, and
    /// shuffle goes through the existing playlist-backed path.
    case playlist(String)

    /// A bounded album/artist queue. It plays FROM `source` (the library, which
    /// is not a meaningful thing to replay) but must never be shuffled by that
    /// name, so it carries its own tracks and is never re-fetched.
    ///
    /// `label` and `source` are separate fields on purpose: playback needs the
    /// source to issue `play track N of playlist X`, and the user must never be
    /// shown it. Separation, not deletion.
    case bounded(label: String, source: String, tracks: [TrackListEntry])

    /// What the user is shown and promised. Never an addressable source name.
    var label: String {
        switch self {
        case .playlist(let name): return name
        case .bounded(let label, _, _): return label
        }
    }
}

/// Classify a finished queue.
///
/// The discriminator is the source's addressability, not the presence of a
/// `displayName`. A library-sourced queue can never be meaningfully replayed by
/// name — `play playlist "Library"` is 14k tracks — so it is bounded to the
/// tracks it already holds, whatever it happens to be labelled.
func continuationSource(for queue: AppQueue) -> ContinuationSource {
    guard isLibraryContextName(queue.playlistName) else {
        return .playlist(queue.playlistName)
    }
    return .bounded(label: queue.contextLabel, source: queue.playlistName, tracks: queue.tracks)
}

/// Tracks to shuffle: the queue's own, reordered. `nil` for a playlist source,
/// which shuffles by name through the existing path rather than from memory.
///
/// Each entry keeps its `.index` — the source-playlist position the player
/// consumes — so shuffling the play order never renumbers what gets played.
func continuationShuffleTracks(_ source: ContinuationSource) -> [TrackListEntry]? {
    guard case .bounded(_, _, let tracks) = source else { return nil }
    return tracks.shuffled()
}

/// Rebuild a bounded queue around an already-shuffled track list.
///
/// Keeps `displayName`, which `shufflePlayPlaylist` drops when it rebuilds —
/// dropping it here would re-break the label one continuation later, at the
/// next queue-end.
func shuffledBoundedQueue(label: String, source: String, tracks: [TrackListEntry]) -> AppQueue {
    AppQueue(playlistName: source, tracks: tracks, currentIndex: 1, displayName: label)
}

/// Shuffle a bounded album/artist queue in place: reorder the tracks it already
/// holds and play from the top. Deliberately does NOT fetch — the counterpart
/// `shufflePlayPlaylist` bulk-fetches by name, which for a library-sourced
/// queue would pull all 14k library tracks instead of the album that ended.
func shufflePlayBounded(backend: AppleScriptBackend, appQueue: AppQueueStore,
                        label: String, source: String, tracks: [TrackListEntry]) -> Bool {
    guard !tracks.isEmpty else { return false }
    let queue = shuffledBoundedQueue(label: label, source: source, tracks: tracks.shuffled())
    appQueue.set(queue)
    return playQueueTrack(backend: backend, playlist: source, position: queue.currentSourcePosition)
}

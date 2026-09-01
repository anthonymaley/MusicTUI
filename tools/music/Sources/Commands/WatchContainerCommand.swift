// tools/music/Sources/Commands/WatchContainerCommand.swift
import ArgumentParser
import Foundation

/// One poll: player state, playlist context, and current track identity, each
/// independently guarded so one throwing read does not blank the others. An
/// empty field means that read threw, which the parser turns into nil.
func albumWatcherObservationScript() -> String {
    """
    set fs to (ASCII character 31)
    set playerStateText to ""
    set contextName to ""
    set trackID to ""
    try
        set playerStateText to player state as text
    end try
    try
        set contextName to name of current playlist
    end try
    try
        set trackID to persistent ID of current track
    end try
    return playerStateText & fs & contextName & fs & trackID
    """
}

func parseWatcherObservation(_ raw: String, containerName: String, ids: Set<String>)
    -> AlbumWatcherObservation {
    let parts = raw.split(separator: asFieldSep, maxSplits: 2, omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    // The real observation script always emits exactly two field separators
    // (three fields), whatever throws inside it. A payload that does not
    // split into exactly three parts is not a partially-empty read, it is a
    // malformed payload entirely, and must spare rather than expose whatever
    // garbage landed in field 0 as a fake player state.
    guard parts.count == 3 else {
        return AlbumWatcherObservation(playerState: nil,
                                       currentPlaylist: nil,
                                       currentTrackID: nil,
                                       containerName: containerName,
                                       containerTrackIDs: ids)
    }
    func field(_ i: Int) -> String? {
        parts[i].isEmpty ? nil : parts[i]
    }
    return AlbumWatcherObservation(playerState: field(0),
                                   currentPlaylist: field(1),
                                   currentTrackID: field(2),
                                   containerName: containerName,
                                   containerTrackIDs: ids)
}

/// Wraps `parseWatcherObservation`, additionally enforcing that when the
/// watcher has no track-identity ground truth (`trackIDs` empty — no
/// `--ids`, an unreadable or missing `--manifest`, or a malformed `--ids`
/// such as `","` that parses to nothing) the observation's `currentTrackID`
/// is forced to nil rather than left populated against an empty set.
///
/// This matters because `albumWatcherDecision` treats `currentTrackID` as
/// ground truth whenever it is present:
///
///     if let id = o.currentTrackID {
///         return o.containerTrackIDs.contains(id) ? .spare : .collect
///     }
///
/// An EMPTY `containerTrackIDs` answers `.contains` false for every track,
/// including the container's own, so a track that IS the container resolves
/// to `.collect` — deleting a playlist the user is actively listening to.
/// That inverts every other fail-safe in this file, and worse, it triggers
/// on the SUCCESS path: the read didn't fail, the caller just never
/// supplied a way to know which tracks are the container's. Forcing
/// `currentTrackID` to nil here routes the decision to its designed
/// fallback, context comparison, instead — `albumWatcherDecision` itself is
/// untouched, correct, and tested; the fix is upstream of it.
func resolvedWatcherObservation(_ raw: String, containerName: String, trackIDs: Set<String>)
    -> AlbumWatcherObservation {
    let o = parseWatcherObservation(raw, containerName: containerName, ids: trackIDs)
    guard trackIDs.isEmpty else { return o }
    return AlbumWatcherObservation(playerState: o.playerState,
                                   currentPlaylist: o.currentPlaylist,
                                   currentTrackID: nil,
                                   containerName: o.containerName,
                                   containerTrackIDs: o.containerTrackIDs)
}

/// Pure parse of the two ways the watcher can learn its container's track
/// identity. Mirrors `run()`'s original `--ids`-then-`--manifest` branching
/// exactly, just factored out so it is directly testable. Neither source
/// producing a usable set (`--ids` unset or malformed such as `","`, or
/// `--manifest` missing/unreadable/racing its writer) is not an error here —
/// it just means the watcher runs context-only, via
/// `resolvedWatcherObservation` above.
func resolveTrackIDs(idsOption: String?, manifestPath: String?) -> Set<String> {
    if let idsOption, !idsOption.isEmpty {
        return Set(idsOption.split(separator: ",").map(String.init))
    }
    if let manifestPath, let fromFile = readAlbumManifest(path: manifestPath) {
        return fromFile
    }
    return []
}

/// The watcher's three-phase decision lifecycle: arm, watch, timeout.
/// Extracted from `run()` for testability — this is detached, silent,
/// playlist-DELETING code whose four exit paths (arm timeout, collect, max
/// lifetime, an unreadable poll) would otherwise only ever be checked by a
/// human reading the diff.
///
/// `now`/`sleep` are injected (defaulting to the real wall clock) so tests
/// can drive a virtual clock instead of waiting out real timeouts.
///
/// Returns whether the container should be deleted. Performs no side
/// effects itself (no delete, no manifest removal) — `executeAlbumWatcher`
/// owns those.
func albumWatcherLifecycle(
    name: String,
    trackIDs: Set<String>,
    run: ScriptRunner,
    now: () -> Date = Date.init,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    armTimeout: TimeInterval = albumWatcherArmTimeout,
    pollInterval: TimeInterval = albumWatcherPollInterval,
    maxLifetime: TimeInterval = albumWatcherMaxLifetime
) -> Bool {
    if trackIDs.isEmpty {
        verbose("album watcher \(name): no track identity available, running context-only")
    }
    func observe() -> AlbumWatcherObservation? {
        guard let raw = run(albumWatcherObservationScript()) else { return nil }
        return resolvedWatcherObservation(raw, containerName: name, trackIDs: trackIDs)
    }

    // Phase 1, arm. Exit without deleting if never observed as current.
    let armDeadline = now().addingTimeInterval(armTimeout)
    var armed = false
    while now() < armDeadline {
        if let o = observe(), o.currentPlaylist == name { armed = true; break }
        sleep(1)
    }
    guard armed else { return false }

    // Phase 2, watch.
    let hardDeadline = now().addingTimeInterval(maxLifetime)
    while now() < hardDeadline {
        sleep(pollInterval)
        guard let o = observe() else { continue }
        if albumWatcherDecision(o) == .collect { return true }
    }

    // Phase 3, timeout. Never delete: the container may still be paused.
    return false
}

/// Runs the lifecycle to a decision, then performs its exactly-once side
/// effects: delete iff `.collect`, and remove the manifest (if one was
/// given) on EVERY exit path — the manifest is owned by the watcher.
///
/// Split out of `run()` so `Foundation.exit(0)` is the only line left that a
/// test cannot exercise directly.
@discardableResult
func executeAlbumWatcher(
    name: String,
    trackIDs: Set<String>,
    manifestPath: String?,
    run: ScriptRunner,
    now: () -> Date = Date.init,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    armTimeout: TimeInterval = albumWatcherArmTimeout,
    pollInterval: TimeInterval = albumWatcherPollInterval,
    maxLifetime: TimeInterval = albumWatcherMaxLifetime
) -> Bool {
    let shouldDelete = albumWatcherLifecycle(name: name, trackIDs: trackIDs, run: run,
                                             now: now, sleep: sleep,
                                             armTimeout: armTimeout, pollInterval: pollInterval,
                                             maxLifetime: maxLifetime)
    if shouldDelete { _ = run(playlistDeleteScript(name: name)) }
    if let manifestPath { removeAlbumManifest(path: manifestPath) }
    return shouldDelete
}

/// Internal plumbing: the one shot cleanup watcher for a bounded album play.
///
/// Spawned detached by the album play path and reparented to launchd. It waits
/// for its container to become current, watches it, deletes exactly that one
/// container when playback leaves it, and exits. It never sweeps by prefix, and
/// on the max lifetime timeout it exits WITHOUT deleting rather than risk
/// destroying a paused album the user intends to resume.
struct WatchContainer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__watch-container",
        abstract: "Internal: delete one temp album container when playback leaves it.",
        shouldDisplay: false)

    @Argument(help: "Exact container playlist name") var name: String
    @Option(name: .long, help: "Comma separated persistent IDs") var ids: String?
    @Option(name: .long, help: "Path to a manifest of persistent IDs") var manifest: String?

    func run() throws {
        let backend = AppleScriptBackend()
        func music(_ script: String) -> String? {
            try? syncRun { try await backend.runMusic(script) }
        }
        let trackIDs = resolveTrackIDs(idsOption: ids, manifestPath: manifest)
        executeAlbumWatcher(name: name, trackIDs: trackIDs, manifestPath: manifest, run: music)
        Foundation.exit(0)
    }
}

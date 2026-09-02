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

/// §16.3: observes whether Music is running WITHOUT launching it.
/// `tell application "Music"` sends an Apple Event that launches a quit
/// application — the very thing this exists to prevent, since the watcher
/// polls every `albumWatcherPollInterval` for up to `albumWatcherMaxLifetime`
/// (six hours), long after the process that spawned it may be gone. This
/// deliberately never references `application "Music"` at all: it asks
/// System Events for process existence instead, which needs no accessibility
/// permission (verified working in this environment 2026-09-01). Checked
/// before every `tell application "Music"` operation in the watcher.
func musicIsRunningScript() -> String {
    "tell application \"System Events\" to return (exists process \"Music\")"
}

/// The real running-observation probe: runs `musicIsRunningScript()` through
/// `AppleScriptBackend.run` directly (never `.runMusic`, which always wraps
/// its argument in `tell application "Music" ... end tell` and would defeat
/// the entire point). The default for `isRunning:` below, mirroring `launch:
/// ProcessLauncher = detachedLaunch` — a real implementation as the default,
/// with an injected seam for tests. A test that cares about this check must
/// still pass an explicit closure rather than rely on the default, exactly
/// as the Safety section requires for `launch`.
func musicIsRunningNow() -> Bool {
    let backend = AppleScriptBackend()
    let raw = try? syncRun { try await backend.run(musicIsRunningScript()) }
    return raw?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
}

/// §16.4: true when `name` is exactly the owned album-container form this
/// watcher may act on — `"__album__ <uuid> — <title>"`, built only by
/// `albumContainerName`. Reuses `albumPlaylistPrefix` and
/// `discoverPlaylistNameSeparator` rather than re-deriving the shape, so the
/// two cannot drift apart.
///
/// Deliberately narrow: a name that is merely prefix-similar, missing the
/// separator, carrying an empty or non-UUID id, or an empty title all fail.
/// This is the ownership check for the only code in this app that deletes a
/// playlist unattended and unobservably — without it, `music
/// __watch-container "Working Vibes"` would delete any playlist by name once
/// it became current and playback left it. Pure → tested.
func isOwnedAlbumContainerName(_ name: String) -> Bool {
    guard name.hasPrefix(albumPlaylistPrefix) else { return false }
    let rest = name.dropFirst(albumPlaylistPrefix.count)
    guard let range = rest.range(of: discoverPlaylistNameSeparator) else { return false }
    let uuidPart = rest[..<range.lowerBound]
    let title = rest[range.upperBound...]
    guard !title.isEmpty else { return false }
    return UUID(uuidString: String(uuidPart)) != nil
}

/// The watcher's three-phase decision lifecycle: arm, watch, timeout.
/// Extracted from `run()` for testability — this is detached, silent,
/// playlist-DELETING code whose exit paths (Music not running, arm timeout,
/// collect, max lifetime, an unreadable poll) would otherwise only ever be
/// checked by a human reading the diff.
///
/// `now`/`sleep`/`isRunning` are all injected, defaulting to a real
/// implementation (`isRunning` to `musicIsRunningNow`, mirroring `launch:
/// ProcessLauncher = detachedLaunch`), so a test that cares must pass an
/// explicit closure rather than rely on the default — same reasoning as
/// `run: ScriptRunner`, which has no default at all.
///
/// §16.3/producer addendum 2026-09-01: "Music is not running" is a
/// LIFECYCLE PRECONDITION, not a predicate input — deliberately kept OUT of
/// `albumWatcherDecision`. The predicate consumes an observation; "Music is
/// not running" means there is no observation to take. So this is checked
/// before generating or executing ANY Music-targeting AppleScript: before
/// arming and before every watch-phase poll, i.e. before every
/// `tell application "Music"` operation this function performs — no code on
/// this path may even build a script string that names `application "Music"`
/// before `isRunning()` has confirmed it. If Music is not running, the
/// lifecycle exits immediately WITHOUT deleting and without ever calling
/// `run`.
///
/// Returns whether the container should be deleted. Performs no side
/// effects itself (no delete, no manifest removal) — `executeAlbumWatcher`
/// owns those, unconditionally, on every exit path.
func albumWatcherLifecycle(
    name: String,
    trackIDs: Set<String>,
    run: ScriptRunner,
    isRunning: () -> Bool = musicIsRunningNow,
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
        guard isRunning() else {
            verbose("album watcher \(name): Music is not running, exiting without touching the playlist")
            return false
        }
        if let o = observe(), o.currentPlaylist == name { armed = true; break }
        sleep(1)
    }
    guard armed else { return false }

    // Phase 2, watch.
    let hardDeadline = now().addingTimeInterval(maxLifetime)
    while now() < hardDeadline {
        sleep(pollInterval)
        guard isRunning() else {
            verbose("album watcher \(name): Music is not running, exiting without touching the playlist")
            return false
        }
        guard let o = observe() else { continue }
        if albumWatcherDecision(o) == .collect { return true }
    }

    // Phase 3, timeout. Never delete: the container may still be paused.
    return false
}

/// Runs the lifecycle to a decision, then performs its exactly-once side
/// effects: delete iff `.collect` AND Music is still observed running (§16.3
/// — belt and braces alongside the lifecycle's own checks, since the delete
/// is itself a `tell application "Music"` operation), and remove the
/// manifest (if one was given) on EVERY exit path — the manifest is owned by
/// the watcher.
///
/// Split out of `run()` so `Foundation.exit(0)` is the only line left that a
/// test cannot exercise directly.
@discardableResult
func executeAlbumWatcher(
    name: String,
    trackIDs: Set<String>,
    manifestPath: String?,
    run: ScriptRunner,
    isRunning: () -> Bool = musicIsRunningNow,
    now: () -> Date = Date.init,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    armTimeout: TimeInterval = albumWatcherArmTimeout,
    pollInterval: TimeInterval = albumWatcherPollInterval,
    maxLifetime: TimeInterval = albumWatcherMaxLifetime
) -> Bool {
    let shouldDelete = albumWatcherLifecycle(name: name, trackIDs: trackIDs, run: run,
                                             isRunning: isRunning,
                                             now: now, sleep: sleep,
                                             armTimeout: armTimeout, pollInterval: pollInterval,
                                             maxLifetime: maxLifetime)
    if shouldDelete && isRunning() { _ = run(playlistDeleteScript(name: name)) }
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
        // §16.4: ownership is checked, not assumed — BEFORE the manifest is
        // read and BEFORE any AppleScript runs. This is the only unattended,
        // unobservable delete path in the app (stdin/stdout/stderr all go to
        // /dev/null in the real detached process), so there is no console to
        // report to either way; refusing silently is consistent with that.
        guard isOwnedAlbumContainerName(name) else {
            verbose("__watch-container: refusing unowned name \(name)")
            Foundation.exit(1)
        }
        let backend = AppleScriptBackend()
        func music(_ script: String) -> String? {
            try? syncRun { try await backend.runMusic(script) }
        }
        let trackIDs = resolveTrackIDs(idsOption: ids, manifestPath: manifest)
        // `isRunning` defaults to `musicIsRunningNow` (§16.3) — omitted here
        // deliberately, so production always gets the real probe.
        executeAlbumWatcher(name: name, trackIDs: trackIDs, manifestPath: manifest, run: music)
        Foundation.exit(0)
    }
}

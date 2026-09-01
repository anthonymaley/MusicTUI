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

        var trackIDs: Set<String> = []
        if let ids, !ids.isEmpty {
            trackIDs = Set(ids.split(separator: ",").map(String.init))
        } else if let manifest, let fromFile = readAlbumManifest(path: manifest) {
            trackIDs = fromFile
        }
        func finish(delete: Bool) -> Never {
            if delete { _ = music(playlistDeleteScript(name: name)) }
            if let manifest { removeAlbumManifest(path: manifest) }
            Foundation.exit(0)
        }

        // Phase 1, arm. Exit without deleting if never observed as current.
        let armDeadline = Date().addingTimeInterval(albumWatcherArmTimeout)
        var armed = false
        while Date() < armDeadline {
            if let raw = music(albumWatcherObservationScript()) {
                let o = parseWatcherObservation(raw, containerName: name, ids: trackIDs)
                if o.currentPlaylist == name { armed = true; break }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        guard armed else { finish(delete: false) }

        // Phase 2, watch.
        let hardDeadline = Date().addingTimeInterval(albumWatcherMaxLifetime)
        while Date() < hardDeadline {
            Thread.sleep(forTimeInterval: albumWatcherPollInterval)
            guard let raw = music(albumWatcherObservationScript()) else { continue }
            let o = parseWatcherObservation(raw, containerName: name, ids: trackIDs)
            if albumWatcherDecision(o) == .collect { finish(delete: true) }
        }

        // Phase 3, timeout. Never delete: the container may still be paused.
        finish(delete: false)
    }
}

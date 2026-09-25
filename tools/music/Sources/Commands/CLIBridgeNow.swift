// tools/music/Sources/Commands/CLIBridgeNow.swift
import Foundation

/// S2, D5. Pure rendering for the CLI's `now` and Bridge play results — every
/// input is a `SourceStatus` (`StationSearchSource.swift`) or explicit counts
/// already in hand. No socket, no dispatch, no command wiring: those are S5–S7.

/// The shape of a Bridge play result, so `bridgePlayResultLines`/
/// `bridgePlayResultJSON` can pick D5's wording and JSON fields without a
/// second copy of the branching at every call site.
enum BridgePlayResultKind: Equatable {
    case playlist
    case album
    case artist
    case song
    /// Bare `music play` (resume): D5 "resume none" — no result line, no
    /// extra JSON fields.
    case resume
}

/// D5's `now` text: the title line when a title exists (`Title — Artist
/// [Bridge]`, or `Title [Bridge]` with no artist), else `Bridge is <state>.`;
/// then `bridgeStatusLine` and `bridgePositionLine` (`Shell/BridgeNow.swift`),
/// each evaluated independently of the title line. `Nothing playing on
/// Bridge.` replaces the state line only in the quiet case: no title, no
/// queue phase reported, and the raw state is idle or stopped — loading and
/// an invalid queue always keep their own state line instead.
func bridgeNowLines(_ status: SourceStatus) -> [String] {
    let b = bridgeNow(from: status)
    let title = status.title ?? ""
    let artist = status.artist ?? ""
    var lines: [String] = []
    if !title.isEmpty {
        lines.append(artist.isEmpty ? "\(title) [Bridge]" : "\(title) \u{2014} \(artist) [Bridge]")
    } else if b.queue == .none, status.playback == "idle" || status.playback == "stopped" {
        lines.append("Nothing playing on Bridge.")
    } else {
        lines.append("Bridge is \(status.playback).")
    }
    if let statusLine = bridgeStatusLine(b) { lines.append(statusLine) }
    if let positionLine = bridgePositionLine(b) { lines.append(positionLine) }
    return lines
}

/// D5's `now` JSON: `output`, `state` (Bridge's raw playback word), `track`/
/// `artist` only when non-empty, and `queue` — `phase`, `requested`,
/// `present`, `index`, `reason`, `built_before_failure`, each only when
/// present — whenever Bridge reports a phase at all, independent of title.
/// Never `album`, `duration`, `position`, `speakers` or `live`.
func bridgeNowJSON(_ status: SourceStatus) -> [String: Any] {
    var dict: [String: Any] = ["output": "bridge", "state": status.playback]
    if let title = status.title, !title.isEmpty { dict["track"] = title }
    if let artist = status.artist, !artist.isEmpty { dict["artist"] = artist }
    if let phase = status.queuePhase {
        var queue: [String: Any] = ["phase": phase]
        if let requested = status.queueRequested { queue["requested"] = requested }
        if let present = status.queuePresent { queue["present"] = present }
        if let index = status.queueIndex { queue["index"] = index }
        if let reason = status.queueReason { queue["reason"] = reason }
        if let built = status.queueBuiltBeforeFailure { queue["built_before_failure"] = built }
        dict["queue"] = queue
    }
    return dict
}

/// D5's play-result first line. `sent` is the id count queued to Bridge; `k`
/// (`skippedUnavailable`) and `v` (`skippedVideos`, playlists only) are
/// Bridge's own counts. The caller (S7) appends "the now text" separately
/// with its own `bridgeNowLines` call — this function renders only the
/// result line(s), never the state that follows.
func bridgePlayResultLines(kind: BridgePlayResultKind, label: String, sent: Int,
                           skippedUnavailable: Int, skippedVideos: Int, shuffle: Bool) -> [String] {
    switch kind {
    case .resume:
        return []
    case .playlist:
        return [bridgePlaylistPlayMessage(name: label, queued: sent, skippedVideos: skippedVideos,
                                          skippedUnavailable: skippedUnavailable, startAt: 1, shuffle: shuffle)]
    case .album, .artist:
        let queued = sent - skippedUnavailable
        var line = "Playing '\(label)' on Bridge \u{2014} \(queued) tracks."
        let notice = bridgeUnavailableSongsNotice(skippedUnavailable)
        if !notice.isEmpty { line += " " + notice }
        return [line]
    case .song:
        return ["Playing '\(label)' on Bridge."]
    }
}

/// D5's play-result JSON fields — `sent`, `queued` (`sent - skippedUnavailable`),
/// `skipped_unavailable`, and, for playlists only, `skipped_videos` and
/// `playlist_members` (`sent + skippedVideos`). The caller (S7) merges this
/// with a separate `bridgeNowJSON` call into one document. `resume` adds
/// nothing (D5 "resume none").
func bridgePlayResultJSON(kind: BridgePlayResultKind, sent: Int,
                          skippedUnavailable: Int, skippedVideos: Int) -> [String: Any] {
    guard kind != .resume else { return [:] }
    var dict: [String: Any] = [
        "sent": sent,
        "queued": sent - skippedUnavailable,
        "skipped_unavailable": skippedUnavailable,
    ]
    if kind == .playlist {
        dict["skipped_videos"] = skippedVideos
        dict["playlist_members"] = sent + skippedVideos
    }
    return dict
}

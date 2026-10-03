// tools/music/Sources/TUI/DiscoverAlbumSongGuard.swift
//
// The song guard of album-cleanup (score step A4, design 4.6 checks b-e).
// This is the ONLY code that deletes songs from his library. A song is
// deleted only when it is `owned` (proven ours), only by its persistent ID,
// and only after the decision-6 keep checks pass inside the same script,
// immediately before the delete:
//   - membership in any of his user playlists other than ours keeps it
//     (smart playlists do not keep, ruling N4);
//   - a song held by ANOTHER live MusicTUI container is spared until that
//     container is gone (CH15), never kept and never ignored;
//   - favorited keeps it; album favorited keeps it;
//   - the song playing now is spared.
// Every unreadable fact fails closed: no delete.
import Foundation

/// The guard script for one song, run inside `tell application "Music"`.
/// `hex` is the song's persistent ID; `live` the persistent IDs of the other
/// live MusicTUI containers (`discoverLiveContainerHexes`). Answers:
///   `gone`                    not in the library (before or after the scan);
///   `unreadable`              the song, the playlist list or a loved flag
///                             could not be read, or several songs matched;
///   `kept|playlist|<name>`    a non-smart playlist of his holds it (or its
///                             count was unreadable);
///   `spared`                  a live MusicTUI container holds it, or it is
///                             (or may be) the current track while not stopped;
///   `kept|loved`, `kept|album` favorited, album favorited;
///   `deleted` / `still`       deleted and then read absent / present
///                             (only when `delete`);
///   `checked`                 every check passed (only when not `delete`).
/// With an empty `live` the live-container branch is omitted entirely. With
/// `delete` false the script holds no `delete` at all. A malformed `hex` or
/// live hex builds a script that touches nothing and answers `unreadable`
/// (the deleter never asks for one).
func discoverOwnedSongGuardScript(hex: String, live: [String], delete: Bool) -> String {
    guard isPersistentIDHex(hex), live.allSatisfy(isPersistentIDHex) else {
        return "return \"unreadable\""
    }
    let holdLines: String
    if live.isEmpty {
        holdLines = """
                if plHitCount is not 0 then return "kept|playlist|" & plNameText
        """
    } else {
        let liveTest = live.map { "plIDText is \"\($0)\"" }.joined(separator: " or ")
        holdLines = """
                if \(liveTest) then
                    if plHitCount is not 0 then set liveHolds to true
                else
                    if plHitCount is not 0 then return "kept|playlist|" & plNameText
                end if
        """
    }
    let checks = """
    set songHits to (every track of library playlist 1 whose persistent ID is "\(hex)")
    if (count of songHits) is 0 then return "gone"
    if (count of songHits) is not 1 then return "unreadable"
    set userLists to missing value
    try
        set userLists to every user playlist
    end try
    if userLists is missing value then return "unreadable"
    set liveHolds to false
    repeat with plRef in userLists
        set plSmart to missing value
        try
            set plSmart to smart of plRef
        end try
        set plIDText to ""
        try
            set plIDText to (persistent ID of plRef) as text
        end try
        set plNameText to ""
        try
            set plNameText to (name of plRef) as text
        end try
        if plSmart is not true then
            set plHitCount to -1
            try
                set plHitCount to count of (tracks of plRef whose persistent ID is "\(hex)")
            end try
    \(holdLines)
        end if
    end repeat
    if liveHolds then return "spared"
    set songHits to (every track of library playlist 1 whose persistent ID is "\(hex)")
    if (count of songHits) is 0 then return "gone"
    set songRef to item 1 of songHits
    set lovedFlag to missing value
    try
        set lovedFlag to favorited of songRef
    end try
    if lovedFlag is missing value then return "unreadable"
    if lovedFlag is true then return "kept|loved"
    set albumLovedFlag to missing value
    try
        set albumLovedFlag to album favorited of songRef
    end try
    if albumLovedFlag is missing value then return "unreadable"
    if albumLovedFlag is true then return "kept|album"
    set stateText to "\(unreadablePlayerStateFallback)"
    try
        set stateText to (player state as text)
    end try
    if stateText is not "stopped" then
        set currentSongID to ""
        try
            set currentSongID to (persistent ID of current track) as text
        end try
        if currentSongID is "" or currentSongID is "\(hex)" then return "spared"
    end if
    """
    guard delete else {
        return checks + "\nreturn \"checked\""
    }
    return checks + """

    delete songRef
    set afterHits to (every track of library playlist 1 whose persistent ID is "\(hex)")
    if (count of afterHits) is 0 then return "deleted"
    return "still"
    """
}

/// The guard's answer, or nil for no answer (the call failed or timed out)
/// and for any text the guard never gives. `kept|playlist|` takes the WHOLE
/// remainder as the name: a name may hold `|` and quotes.
func parseDiscoverSongGuardAnswer(_ output: String?) -> DiscoverSongGuardAnswer? {
    guard let output else { return nil }
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let playlistPrefix = "kept|playlist|"
    if text.hasPrefix(playlistPrefix) {
        return .keptPlaylist(String(text.dropFirst(playlistPrefix.count)))
    }
    switch text {
    case "gone": return .gone
    case "kept|loved": return .keptLoved
    case "kept|album": return .keptAlbum
    case "spared": return .spared
    case "deleted": return .deleted
    case "still": return .still
    case "unreadable": return .unreadable
    case "checked": return .checked
    default: return nil
    }
}

/// Hexes of every entry in owned or listening whose containerGone is not true, except `txn`'s;
/// nil when any such hex is malformed (then nothing runs). Copy entries count
/// too: a live MusicTUI copy is as much ours as a live album container. A
/// `preexisting` entry's playlist is his, so it is never here.
func discoverLiveContainerHexes(_ entries: [DiscoverCopyEntry], excluding txn: String) -> [String]? {
    var hexes: [String] = []
    for entry in entries where entry.txn != txn {
        guard entry.state == .owned || entry.state == .listening, entry.containerGone != true else { continue }
        guard let hex = entry.hex, isPersistentIDHex(hex) else { return nil }
        if !hexes.contains(hex) { hexes.append(hex) }
    }
    return hexes
}

/// One guard item: one song of one album entry, on the action queue.
struct DiscoverOwnedSongDeleter {
    private let journal: DiscoverCopyJournalStore
    private let run: ScriptRunner
    private let now: () -> Date

    /// `run` is the runner W gives it, bounded by `guardScriptTimeout`; nil is
    /// a failed or timed-out call.
    init(journal: DiscoverCopyJournalStore, run: @escaping ScriptRunner, now: @escaping () -> Date) {
        self.journal = journal
        self.run = run
        self.now = now
    }

    /// An unreadable journal -> `.retry` with no strike counted and no script
    /// (`strikes: 0`, since the count could not be read). No script, `.notRun`,
    /// unless the entry is an album entry whose container is gone, the song is
    /// `owned` with a well-formed entry hex, and the live containers are
    /// readable. A song already `deleted` or `kept` is `.notRun`, so a second
    /// item never deletes twice. When the answer's journal write fails the
    /// song stays `owned` and the item answers `.retry` with the unchanged
    /// strike count: the next item asks again, and a song that was deleted
    /// then reads `gone`.
    func run(txn: String, position: Int) -> DiscoverSongGuardOutcome {
        let entries: [DiscoverCopyEntry]
        do {
            entries = try journal.entries()
        } catch {
            return .retry(strikes: 0)
        }
        guard let entry = entries.first(where: { $0.txn == txn }),
              entry.kind == .albumContainer,
              entry.containerGone == true,
              let song = entry.songs?.first(where: { $0.position == position }),
              song.state == .owned,
              let hex = song.entryHex, isPersistentIDHex(hex),
              let live = discoverLiveContainerHexes(entries, excluding: txn) else {
            return .notRun
        }

        let answer = parseDiscoverSongGuardAnswer(run(discoverOwnedSongGuardScript(hex: hex, live: live, delete: true)))
        switch answer {
        case .deleted?, .gone?:
            let at = now().timeIntervalSince1970
            return record(txn: txn, position: position, strikes: song.guardStrikes, outcome: .deleted) {
                $0.state = .deleted
                $0.deletedAt = at
            }
        case .keptLoved?:
            return keep(txn: txn, position: position, strikes: song.guardStrikes, reason: "loved", playlist: nil)
        case .keptAlbum?:
            return keep(txn: txn, position: position, strikes: song.guardStrikes, reason: "album", playlist: nil)
        case .keptPlaylist(let name)?:
            return keep(txn: txn, position: position, strikes: song.guardStrikes, reason: "playlist", playlist: name)
        case .spared?:
            return .spared
        case .still?, .unreadable?, .checked?, nil:
            let strikes = song.guardStrikes + 1
            if strikes >= DiscoverAlbumTiming.guardStrikes {
                return record(txn: txn, position: position, strikes: song.guardStrikes, outcome: .gaveUp) {
                    $0.guardStrikes = strikes
                    $0.state = .kept
                    $0.keptReason = "couldn't check"
                    $0.keptPlaylist = nil
                }
            }
            return record(txn: txn, position: position, strikes: song.guardStrikes,
                          outcome: .retry(strikes: strikes)) {
                $0.guardStrikes = strikes
            }
        }
    }

    private func keep(txn: String, position: Int, strikes: Int,
                      reason: String, playlist: String?) -> DiscoverSongGuardOutcome {
        record(txn: txn, position: position, strikes: strikes, outcome: .kept(reason: reason, playlist: playlist)) {
            $0.state = .kept
            $0.keptReason = reason
            $0.keptPlaylist = playlist
        }
    }

    /// Applies `change` to the song in one durable update, only while it is
    /// still `owned`. `outcome` when written, else `.retry(strikes:)` with the
    /// strike count as it was.
    private func record(txn: String, position: Int, strikes: Int, outcome: DiscoverSongGuardOutcome,
                        _ change: (inout DiscoverAlbumSong) -> Void) -> DiscoverSongGuardOutcome {
        var applied = false
        do {
            try journal.update(txn: txn) { entry in
                guard var songs = entry.songs,
                      let index = songs.firstIndex(where: { $0.position == position }),
                      songs[index].state == .owned else { return }
                change(&songs[index])
                entry.songs = songs
                entry.updatedAt = Int(now().timeIntervalSince1970)
                applied = true
            }
        } catch {
            return .retry(strikes: strikes)
        }
        return applied ? outcome : .retry(strikes: strikes)
    }
}

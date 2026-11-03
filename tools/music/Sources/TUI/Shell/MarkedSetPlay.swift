// tools/music/Sources/TUI/Shell/MarkedSetPlay.swift
import Foundation

// MARK: - The marked set as one queue (combined play, step 3)
//
// The rows marked with `m` on the Albums and Playlists rails play as ONE
// app-owned queue, in mark order, addressed by persistent ID
// (`persistentIDQueueSource`), so the poller's advance, next/previous, Now's
// jump and the bounded end-of-queue continuation all play exactly these
// tracks. It is a temporary queue only: everything here READS. Nothing makes,
// duplicates, renames or deletes a playlist or a track.

/// The three reads a marked play makes, injected so the queue is built and
/// tested without Music.
struct MarkedSetReaders {
    /// An album's playable tracks as identity-addressed entries
    /// (`resolveAlbumPlaybackTrackIDs`).
    let album: (_ title: String, _ artist: String) -> AlbumResolution
    /// How many playlists carry exactly this name; nil when the read failed.
    let playlistsNamed: (_ name: String) -> Int?
    /// A playlist's tracks as identity-addressed entries, in playlist order;
    /// nil when the read failed (`fetchPlaylistTrackIDs`).
    let playlist: (_ name: String) -> [TrackListEntry]?

    /// The AppleScript readers. Read-only scripts, every one.
    static func live(backend: AppleScriptBackend) -> MarkedSetReaders {
        MarkedSetReaders(
            album: { resolveAlbumPlaybackTrackIDs(backend: backend, title: $0, artist: $1) },
            playlistsNamed: { name in
                guard let raw = try? backend.runMusicBlocking(playlistsNamedScript(name)) else { return nil }
                return parsePlaylistsNamedCount(raw)
            },
            playlist: { fetchPlaylistTrackIDs(backend: backend, playlist: $0) })
    }
}

/// Counts the playlists named exactly `name`, of every kind, because
/// `playlist "<name>"` (which the track read addresses) resolves against all of
/// them and silently takes the first. A read: it changes nothing.
func playlistsNamedScript(_ name: String) -> String {
    "count of (every playlist whose name is \"\(escapeAppleScriptString(name))\")"
}

/// The count `playlistsNamedScript` answers, or nil for anything that is not
/// a whole number. Pure.
func parsePlaylistsNamedCount(_ raw: String) -> Int? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let n = Int(text), n >= 0 else { return nil }
    return n
}

/// What Now Playing calls the marked set: the one item's own name, else
/// "2 albums and 1 playlist" (either half alone when the other is absent).
func markedSetDisplayName(_ items: [MarkedItem]) -> String {
    if items.count == 1 {
        switch items[0] {
        case .album(let title, _): return title
        case .playlist(let name): return name
        }
    }
    var albums = 0, playlists = 0
    for item in items {
        if case .album = item { albums += 1 } else { playlists += 1 }
    }
    func counted(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
    switch (albums, playlists) {
    case (0, let p): return counted(p, "playlist")
    case (let a, 0): return counted(a, "album")
    case (let a, let p): return "\(counted(a, "album")) and \(counted(p, "playlist"))"
    }
}

/// The marked rows as one queue: each item's tracks, in mark order (shuffled
/// together when `shuffle`), addressed by persistent ID and labelled by
/// `markedSetDisplayName`. Fails closed and whole: any read that fails, an
/// album with nothing to play, a playlist that is gone, empty, or shares its
/// name with another playlist throws an `ActionError` naming that item, and
/// no queue exists. Reads stop at the first failure.
func markedSetQueue(_ items: [MarkedItem], shuffle: Bool, readers: MarkedSetReaders) throws -> AppQueue {
    guard !items.isEmpty else { throw ActionError(message: "Nothing is marked.") }
    var entries: [TrackListEntry] = []
    for item in items {
        switch item {
        case .album(let title, let artist):
            let res = readers.album(title, artist)
            if res.readFailed {
                throw ActionError(message: "Music didn't answer while reading '\(title)', so nothing played. Try again.")
            }
            guard !res.tracks.isEmpty else {
                throw ActionError(message: res.matched > 0
                    ? "'\(title)' has no tracks available to play yet, so nothing played."
                    : "Couldn't find the album '\(title)', so nothing played.")
            }
            entries += res.tracks
        case .playlist(let name):
            guard let named = readers.playlistsNamed(name) else {
                throw ActionError(message: "Music didn't answer while reading '\(name)', so nothing played. Try again.")
            }
            guard named > 0 else {
                throw ActionError(message: "Couldn't find the playlist '\(name)', so nothing played.")
            }
            guard named == 1 else {
                throw ActionError(message: "More than one playlist is named '\(name)', so nothing played. Rename one to play it with the others.")
            }
            guard let tracks = readers.playlist(name) else {
                throw ActionError(message: "Music didn't answer while reading '\(name)', so nothing played. Try again.")
            }
            guard !tracks.isEmpty else {
                throw ActionError(message: "'\(name)' has no tracks, so nothing played.")
            }
            entries += tracks
        }
    }
    return AppQueue(playlistName: persistentIDQueueSource, tracks: shuffle ? entries.shuffled() : entries,
                    currentIndex: 1, displayName: markedSetDisplayName(items))
}

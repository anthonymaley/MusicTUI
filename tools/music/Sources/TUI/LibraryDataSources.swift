// tools/music/Sources/TUI/LibraryDataSources.swift
// The I/O the Library scene depends on, packaged as closures so the scene holds
// no direct REST/AppleScript knowledge (mirrors PlaylistDataSources). Albums are
// the only wired sub-view for now; Artists/Songs land in later tasks.
import Foundation

struct LibraryDataSources {
    let onAlbums: () -> [LibraryAlbum]
    let onAlbumTracks: (_ albumTitle: String, _ artist: String) -> [String]
    let onSongs: () -> [LibrarySong]
    let onArtists: () -> [LibraryArtist]
    let onArtistAlbums: (_ artistID: String) -> [LibraryAlbum]
}

/// Build the Library closures. `onAlbums` hits the REST library endpoint;
/// `onAlbumTracks` reads the whole-library "Library" source playlist via
/// AppleScript, matching by album+artist (the same predicate the play path uses).
/// Both are called off the main thread by the scene.
func makeLibraryDataSources(api: RESTAPIBackend, backend: AppleScriptBackend) -> LibraryDataSources {
    LibraryDataSources(
        onAlbums: { (try? syncRun { try await api.libraryAlbums() }) ?? [] },
        onAlbumTracks: { title, artist in
            let script = """
            set out to ""
            repeat with t in (every track of playlist "Library" whose album is "\(escapeAppleScriptString(title))" and artist is "\(escapeAppleScriptString(artist))")
                set out to out & (name of t) & linefeed
            end repeat
            return out
            """
            let raw = (try? syncRun { try await backend.runMusic(script, timeout: 30) }) ?? ""
            return raw.split(separator: "\n").map(String.init)
        },
        onSongs: { (try? syncRun { try await api.librarySongs() }) ?? [] },
        onArtists: { (try? syncRun { try await api.libraryArtists() }) ?? [] },
        onArtistAlbums: { id in (try? syncRun { try await api.artistAlbums(artistID: id) }) ?? [] }
    )
}

// tools/music/Sources/TUI/LibraryDataSources.swift
// The I/O the Library scene depends on, packaged as closures so the scene holds
// no direct REST/AppleScript knowledge (mirrors PlaylistDataSources). The three
// big paginated lists (albums/songs/artists) STREAM page-by-page for progressive
// render; album-tracks and one artist's albums stay single-shot (small / unpaged).
import Foundation

struct LibraryDataSources {
    // Streaming: each closure walks its paginated endpoint and hands every page to
    // `onPage` as it lands, so the scene renders the first rows after one round-trip
    // instead of after the whole walk. `onPage` returns false to abort mid-walk
    // (e.g. the scene was torn down). `onAlbumTracks`/`onArtistAlbums` are single
    // AppleScript/REST reads — no paging, so they return their whole result.
    let onAlbums: (_ onPage: ([LibraryAlbum]) -> Bool) -> Void
    let onSongs: (_ onPage: ([LibrarySong]) -> Bool) -> Void
    let onArtists: (_ onPage: ([LibraryArtist]) -> Bool) -> Void
    let onAlbumTracks: (_ albumTitle: String, _ artist: String) -> [String]
    let onArtistAlbums: (_ artistID: String) -> [LibraryAlbum]
}

/// Walk every page of a paginated library list, handing each page to `onPage` as
/// it arrives. Progressive render depends on this: the caller appends each page to
/// its list, so rows show after the first round-trip instead of after the whole
/// walk (a large library was ~140 round-trips of "Loading…"). `onPage` returns
/// false to abort mid-walk (the scene deallocated). The REST endpoints cap a
/// single response at `pageSize` (100), so we advance `offset` until a short page
/// signals exhaustion, or `cap` trips as a safety valve against an endpoint that
/// never returns a short page. A mid-walk failure (page returns []) reads as a
/// short page and stops early — partial is better than a crash. Pure w.r.t. the
/// paging logic, so it's unit-testable with a synchronous fake.
func fetchPagesStreaming<T>(pageSize: Int = 100, cap: Int = 10_000,
                            page: (_ limit: Int, _ offset: Int) -> [T],
                            onPage: (_ batch: [T]) -> Bool) {
    var count = 0
    var offset = 0
    while count < cap {
        let batch = page(pageSize, offset)
        count += batch.count
        if !batch.isEmpty, !onPage(batch) { return }
        if batch.count < pageSize { break }
        offset += pageSize
    }
}

/// Accumulating form of `fetchPagesStreaming`: walk every page and return the whole
/// list in one shot. Kept for callers (and unit tests) that want the full result;
/// the paging logic lives once, in `fetchPagesStreaming`. Same short-page / cap
/// termination.
func fetchAllPages<T>(pageSize: Int = 100, cap: Int = 10_000,
                      _ page: (_ limit: Int, _ offset: Int) -> [T]) -> [T] {
    var all: [T] = []
    fetchPagesStreaming(pageSize: pageSize, cap: cap, page: page) { batch in
        all.append(contentsOf: batch)
        return true
    }
    return all
}

/// Build the Library closures. `onAlbums`/`onSongs`/`onArtists` stream the REST
/// library endpoints page-by-page (see fetchPagesStreaming); `onAlbumTracks` reads
/// the whole-library "Library" source playlist via AppleScript, matching by
/// album+artist (the same predicate the play path uses). All are called off the
/// main thread by the scene.
func makeLibraryDataSources(api: RESTAPIBackend, backend: AppleScriptBackend) -> LibraryDataSources {
    LibraryDataSources(
        onAlbums: { onPage in
            fetchPagesStreaming(page: { limit, offset in
                (try? syncRun { try await api.libraryAlbums(limit: limit, offset: offset) }) ?? []
            }, onPage: onPage)
        },
        onSongs: { onPage in
            fetchPagesStreaming(page: { limit, offset in
                (try? syncRun { try await api.librarySongs(limit: limit, offset: offset) }) ?? []
            }, onPage: onPage)
        },
        onArtists: { onPage in
            fetchPagesStreaming(page: { limit, offset in
                (try? syncRun { try await api.libraryArtists(limit: limit, offset: offset) }) ?? []
            }, onPage: onPage)
        },
        onAlbumTracks: { title, artist in
            let script = """
            set out to ""
            repeat with t in (every track of playlist "Library" whose album is "\(escapeAppleScriptString(title))" and (artist is "\(escapeAppleScriptString(artist))" or album artist is "\(escapeAppleScriptString(artist))"))
                set out to out & (name of t) & linefeed
            end repeat
            return out
            """
            let raw = (try? syncRun { try await backend.runMusic(script, timeout: 30) }) ?? ""
            return raw.split(separator: "\n").map(String.init)
        },
        // One artist's albums are few and the endpoint already asks for 100 — no paging.
        onArtistAlbums: { id in (try? syncRun { try await api.artistAlbums(artistID: id) }) ?? [] }
    )
}

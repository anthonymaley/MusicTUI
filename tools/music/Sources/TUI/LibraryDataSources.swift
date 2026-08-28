// tools/music/Sources/TUI/LibraryDataSources.swift
// The I/O the Library scene depends on, packaged as closures so the scene holds
// no direct REST/AppleScript knowledge (mirrors PlaylistDataSources). The three
// big lists (albums/songs/artists) all come from one bulk AppleScript read of
// playlist "Library", cached per instance in a LibraryIndexCache. onPage is kept
// so the scene's inbox/drain code does not change; each list arrives as exactly
// one page.
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
    let onAlbumCover: (_ albumID: String) -> LibraryCover?
}

/// Walk every page of a limit/offset REST endpoint, handing each page to `onPage`
/// as it arrives. No Library list uses this anymore (they read the bulk
/// AppleScript index instead), but showPlaylistTracks in PlaylistCommands.swift
/// still walks a playlist's tracks this way, so the helper stays. The REST
/// endpoints cap a single response at `pageSize` (100), so we advance `offset`
/// until a short page signals exhaustion, or `cap` trips as a safety valve
/// against an endpoint that never returns a short page. A mid-walk failure (page
/// returns []) reads as a short page and stops early: partial is better than a
/// crash. Pure w.r.t. the paging logic, so it's unit-testable with a synchronous
/// fake.
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
/// list in one shot. Used by showPlaylistTracks to fetch a playlist's tracks past
/// the endpoint's 100-item cap. Same short-page / cap termination.
func fetchAllPages<T>(pageSize: Int = 100, cap: Int = 10_000,
                      _ page: (_ limit: Int, _ offset: Int) -> [T]) -> [T] {
    var all: [T] = []
    fetchPagesStreaming(pageSize: pageSize, cap: cap, page: page) { batch in
        all.append(contentsOf: batch)
        return true
    }
    return all
}

/// Build the Library closures. All four list closures read the SAME cached
/// bulk AppleScript read (LibraryIndexCache); `artworkAPI` is optional and
/// used only by the cover ladder's REST fallback (Step 7), never by a list.
/// The onPage shape is kept: LibraryScene's streaming inboxes are unchanged
/// and each list is delivered as one page. All are called off the main
/// thread by the scene.
func makeLibraryDataSources(backend: AppleScriptBackend, artworkAPI: RESTAPIBackend? = nil) -> LibraryDataSources {
    let index = LibraryIndexCache()
    func rows() -> [LibraryTrackRow] { index.rows { fetchLibraryTrackRows(backend: backend) } }
    return LibraryDataSources(
        onAlbums: { onPage in let a = groupLibraryAlbums(rows()); if !a.isEmpty { _ = onPage(a) } },
        onSongs: { onPage in let s = groupLibrarySongs(rows()); if !s.isEmpty { _ = onPage(s) } },
        onArtists: { onPage in let r = groupLibraryArtists(rows()); if !r.isEmpty { _ = onPage(r) } },
        // Shares resolveAlbumPlaybackTracks with the play path so the preview pane
        // and the actual queue never disagree — including the album-title fallback
        // for albums whose REST artist string has drifted from the stored album
        // artist (which the old strict-only clause left showing an empty tracklist).
        onAlbumTracks: { title, artist in
            resolveAlbumPlaybackTracks(backend: backend, title: title, artist: artist).tracks.map(\.name)
        },
        onArtistAlbums: { id in groupLibraryArtistAlbums(rows(), artistID: id) },
        // Cover ladder for one focused album, run by the scene on its serial
        // previewQueue (never the bulk read): (1) the embedded artwork of the
        // album's first library row, (2) with a keyed, signed-in user, the Now
        // tab's REST lookup by that row's title (NowArtwork.swift, route 3
        // then 4), (3) nil, the gradient. The producer accepted that keyed
        // users lose covers on albums with no embedded art that the lookup
        // misses.
        onAlbumCover: { id in
            guard let first = index.albumRows(id: id)?.first else { return nil }
            let embedded = extractLibraryTrackArtwork(backend: backend, persistentID: first.persistentID,
                                                      to: libraryCoverTempPath(albumID: id))
            let rest = (embedded == nil && artworkAPI != nil)
                ? lookupAlbumArtwork(api: artworkAPI!, title: first.name,
                                     artist: first.albumArtist.isEmpty ? first.artist : first.albumArtist, album: first.album)
                : nil
            return resolveLibraryCover(albumID: id, embeddedPath: embedded, restHit: rest)
        }
    )
}

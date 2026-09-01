// tools/music/Sources/TUI/LibraryIndex.swift
// One bulk AppleScript read of playlist "Library" replaces the three
// paginated REST walks onAlbums/onSongs/onArtists/onArtistAlbums used to
// need. Measured 2026-08-28 on this library: six column gets, joined by text
// item delimiters, read all 14,223 tracks in 0.85s. A per-row repeat loop
// building the same payload measured 26s, and the REST paging it replaces
// measured 7s (artists, 1,760 rows, 18 pages), 47s (albums, 2,963 rows, 30
// pages) and 206s (songs, 14,201 rows, 143 pages). The tab no longer needs a
// developer token or a user token to open.

import Foundation

/// One track of playlist "Library", as read by the bulk script. persistentID is
/// Music's own stable track id (the Songs list id); cloudStatus is the enum as
/// text (seen live: subscription, uploaded, unknown, matched, purchased,
/// "no longer available").
struct LibraryTrackRow: Equatable {
    let persistentID: String
    let name: String
    let artist: String
    let album: String
    let albumArtist: String
    let cloudStatus: String
}

/// Row separator inside one column block of the bulk read (ASCII 30, record
/// separator). Columns are joined by asFieldSep (ASCII 31). Script side:
/// `set rs to (ASCII character 30)`.
let asRowSep: Character = "\u{001E}"

/// The bulk read. Six column gets of every track of playlist "Library",
/// each coerced to text under a record separator delimiter, then joined by
/// the field separator. Measured 2026-08-28: 0.85s for 14,223 tracks. A
/// per-row repeat loop building the same payload measured 26s, and REST
/// paging of the same lists measured 7s (artists), 47s (albums) and 206s
/// (songs), so this is the only acceptable shape. `lib` is bound once so the
/// six gets resolve against one object specifier. No `whose` (a filter stored
/// in a variable loses the bulk read).
func libraryBulkReadScript() -> String {
    """
    set astid to AppleScript's text item delimiters
    set fs to (ASCII character 31)
    set rs to (ASCII character 30)
    set lib to playlist "Library"
    set AppleScript's text item delimiters to rs
    set ids to (persistent ID of every track of lib) as text
    set ns to (name of every track of lib) as text
    set ars to (artist of every track of lib) as text
    set als to (album of every track of lib) as text
    set aas to (album artist of every track of lib) as text
    set css to (cloud status of every track of lib) as text
    set AppleScript's text item delimiters to astid
    return ids & fs & ns & fs & ars & fs & als & fs & aas & fs & css
    """
}

/// Pure parse of the six column blocks into rows by position. Returns [] on
/// anything other than exactly six blocks of equal row count: a mismatch means
/// the payload is corrupt and a misaligned list is worse than an empty one.
func parseLibraryTrackRows(_ raw: String) -> [LibraryTrackRow] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let blocks = trimmed.components(separatedBy: String(asFieldSep))
    guard blocks.count == 6 else { return [] }
    let columns = blocks.map { $0.components(separatedBy: String(asRowSep)) }
    guard let count = columns.first?.count, columns.allSatisfy({ $0.count == count }) else { return [] }
    return (0..<count).map { i in
        LibraryTrackRow(persistentID: columns[0][i], name: columns[1][i], artist: columns[2][i],
                        album: columns[3][i], albumArtist: columns[4][i], cloudStatus: columns[5][i])
    }
}

/// Run the bulk read. 60s watchdog: the read itself is under a second, the
/// margin covers a Music that is still launching. A failure is REPORTED as
/// `.failure`, never as an empty library: the two are different answers and
/// collapsing them is what made a failed read render "(no ...)" permanently.
func fetchLibraryTrackRows(backend: AppleScriptBackend) -> LibraryReadResult {
    // `?? ""` here used to launder a failed AppleScript call into an empty
    // string, which parsed to zero rows and was indistinguishable from an empty
    // library all the way up the stack. The failure is reported instead.
    guard let raw = try? syncRun({ try await backend.runMusic(libraryBulkReadScript(), timeout: 60) }) else {
        return .failure
    }
    return .success(parseLibraryTrackRows(raw))
}

/// The album identity: album name plus its credit, where the credit is the
/// album artist or, when that is empty (3,119 of 14,223 rows here), the track
/// artist. NUL separates because no real name contains it (same shape as
/// nowAlbumKey in NowArtwork.swift). Pure.
func libraryAlbumKey(album: String, albumArtist: String, artist: String) -> String {
    "\(album)\u{0}\(albumArtist.isEmpty ? artist : albumArtist)"
}

/// FNV-1a 64 over the key's UTF-8, as 16 hex digits, prefixed "lib." so an
/// id can never be mistaken for a REST library id ("l.xxx"). Stable across
/// reads and sessions, safe as a file name, and far from collisions over a
/// few thousand albums. Pure.
func libraryAlbumID(forKey key: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    let prime: UInt64 = 0x100000001b3
    for byte in key.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* prime
    }
    return "lib." + String(format: "%016llx", hash)
}

/// Group rows into albums. Sorted by name then artist, case-insensitive via
/// localizedCaseInsensitiveCompare, matching the name order the REST list
/// used so the rail reads the same as before. Rows with an empty album are
/// songs without an album, not albums, and are dropped. trackCount is the
/// number of library rows in the group: the tier filter in LibraryScene
/// relies on that being the IN-LIBRARY count (a loose playlist song is a
/// 1-track stub). artworkURL stays nil: covers are resolved lazily per
/// focused album, never in the bulk read. Pure.
func groupLibraryAlbums(_ rows: [LibraryTrackRow]) -> [LibraryAlbum] {
    var order: [String] = []
    var names: [String: String] = [:]
    var artists: [String: String] = [:]
    var counts: [String: Int] = [:]
    for row in rows where !row.album.isEmpty {
        let artist = row.albumArtist.isEmpty ? row.artist : row.albumArtist
        let key = libraryAlbumKey(album: row.album, albumArtist: row.albumArtist, artist: row.artist)
        if counts[key] == nil {
            order.append(key)
            names[key] = row.album
            artists[key] = artist
        }
        counts[key, default: 0] += 1
    }
    return order
        .map { key -> LibraryAlbum in
            LibraryAlbum(id: libraryAlbumID(forKey: key), name: names[key] ?? "", artist: artists[key] ?? "",
                         trackCount: counts[key] ?? 0)
        }
        .sorted { lhs, rhs in
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
        }
}

/// One song per row, id = persistent ID, sorted by title then artist
/// (case-insensitive). Pure.
func groupLibrarySongs(_ rows: [LibraryTrackRow]) -> [LibrarySong] {
    rows
        .map { LibrarySong(id: $0.persistentID, title: $0.name, artist: $0.artist, album: $0.album) }
        .sorted { lhs, rhs in
            let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
        }
}

/// Distinct credits (album artist, else artist), empty dropped, sorted
/// case-insensitively. id == name: there is no other id, and every consumer
/// (drill-in, playArtist) only ever needed the name. Pure.
func groupLibraryArtists(_ rows: [LibraryTrackRow]) -> [LibraryArtist] {
    var seen = Set<String>()
    var names: [String] = []
    for row in rows {
        let credit = row.albumArtist.isEmpty ? row.artist : row.albumArtist
        guard !credit.isEmpty, !seen.contains(credit) else { continue }
        seen.insert(credit)
        names.append(credit)
    }
    return names
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        .map { LibraryArtist(id: $0, name: $0) }
}

/// One artist's albums: the rows whose credit is artistID, grouped exactly as
/// the whole-library list is, so an album's id is identical at both levels
/// (the track preview cache and the cover cache key on it). Pure.
func groupLibraryArtistAlbums(_ rows: [LibraryTrackRow], artistID: String) -> [LibraryAlbum] {
    groupLibraryAlbums(rows.filter { ($0.albumArtist.isEmpty ? $0.artist : $0.albumArtist) == artistID })
}

/// The bulk read, cached once per LibraryDataSources instance and shared by
/// the three lists, the artist drill-in and the cover ladder. NSLock because
/// the scene calls every source off the main thread (Thread.detachNewThread
/// and previewQueue) and the first two lists can race on the read. The read
/// is cheap (0.85s) but not free, and three concurrent osascript spawns of it
/// would be three seconds of Music being hammered for one answer.
final class LibraryIndexCache {
    private let lock = NSLock()
    private var cached: [LibraryTrackRow]? = nil
    private var albumIndex: [String: [LibraryTrackRow]] = [:]   // album id -> its rows, built with the first load

    /// Rows for the Library tab, or `nil` when nothing has been read yet and the
    /// attempt failed.
    ///
    /// A failure is NEVER cached and never displaces a good cache: `[]` reaching
    /// this cache means a successful read of an empty library and nothing else.
    /// Caching a failure is what made a failed read render "(no albums)" forever,
    /// with nothing left for a retry to act on.
    func rows(load: () -> LibraryReadResult) -> [LibraryTrackRow]? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard case .success(let loaded) = load() else { return nil }
        cached = loaded
        var index: [String: [LibraryTrackRow]] = [:]
        for row in loaded where !row.album.isEmpty {
            let key = libraryAlbumKey(album: row.album, albumArtist: row.albumArtist, artist: row.artist)
            let id = libraryAlbumID(forKey: key)
            index[id, default: []].append(row)
        }
        albumIndex = index
        return loaded
    }

    /// The rows of one album id, or nil when the id is unknown or nothing has
    /// been loaded yet. Used by the cover ladder to pick a representative track.
    func albumRows(id: String) -> [LibraryTrackRow]? {
        lock.lock()
        defer { lock.unlock() }
        return albumIndex[id]
    }
}

/// The result of the cover ladder for one album: key is the ArtworkStore
/// cache key, url is the final fetchable URL (a file URL for embedded bytes,
/// a resolved CDN URL for the REST fallback).
struct LibraryCover: Equatable {
    let key: String
    let url: String
}

/// Embedded artwork of ONE library track, found by persistent ID (unique,
/// so no name matching and no `contains ""` trap). Same write mechanism as
/// extractArtwork(to:) in NowPlayingTUI.swift, which is bound to `current
/// track` and cannot be reused for a browsed album. Pure builder, tested.
func libraryTrackArtworkScript(persistentID: String, path: String) -> String {
    """
    try
        set hits to (every track of playlist "Library" whose persistent ID is "\(escapeAppleScriptString(persistentID))")
        if (count of hits) > 0 then
            set artworks_ to artworks of item 1 of hits
            if (count of artworks_) > 0 then
                set artData to raw data of item 1 of artworks_
                set fileRef to open for access POSIX file "\(escapeAppleScriptString(path))" with write permission
                set eof of fileRef to 0
                write artData to fileRef
                close access fileRef
                return "OK"
            end if
        end if
    end try
    return "NONE"
    """
}

/// Deterministic per-album temp path for extracted bytes (mirrors
/// PlaybackPoller.tempArtPath: one path per album, never shared). The id is
/// already hex-safe. Swept at shell exit by sweepLibraryArtFiles(). Pure.
func libraryCoverTempPath(albumID: String) -> String { "/tmp/music-lib-art-\(albumID).dat" }

/// ArtworkStore key for an album's embedded cover. Distinct from any REST id
/// (those are "l.xxx") so the two never collide in the art cache. Pure.
func libraryEmbeddedCoverKey(albumID: String) -> String { "\(albumID).emb" }

/// The ladder's decision, pure: embedded first (the album's own bytes, no
/// network, no token), REST second (keyed on the REST library album id so
/// the Now tab and this tab share one cached cover), else nil (gradient).
func resolveLibraryCover(albumID: String, embeddedPath: String?, restHit: (id: String, url: String)?) -> LibraryCover? {
    if let p = embeddedPath {
        return LibraryCover(key: libraryEmbeddedCoverKey(albumID: albumID), url: URL(fileURLWithPath: p).absoluteString)
    }
    if let hit = restHit {
        return LibraryCover(key: hit.id, url: ArtworkStore.resolveURL(hit.url, width: 300, height: 300))
    }
    return nil
}

/// Run the extraction. Returns the path on "OK", nil otherwise (no artwork,
/// track gone, script error). Never throws: art is decoration. Mirrors
/// extractArtwork(to:) in NowPlayingTUI.swift, which is bound to `current
/// track` and can't be reused for a browsed album.
func extractLibraryTrackArtwork(backend: AppleScriptBackend, persistentID: String, to path: String) -> String? {
    guard let result = try? syncRun({
        try await backend.runMusic(libraryTrackArtworkScript(persistentID: persistentID, path: path))
    }) else { return nil }
    return result.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" ? path : nil
}

/// Delete this session's extracted covers (/tmp/music-lib-art-*.dat). Called
/// from runShell's exit defer next to poller.cleanupArtFiles(); the bytes
/// already live in the art cache by then, so nothing is lost.
func sweepLibraryArtFiles() {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") else { return }
    for name in entries where name.hasPrefix("music-lib-art-") && name.hasSuffix(".dat") {
        try? FileManager.default.removeItem(atPath: "/tmp/\(name)")
    }
}

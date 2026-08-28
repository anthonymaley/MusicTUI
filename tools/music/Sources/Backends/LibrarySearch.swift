// tools/music/Sources/Backends/LibrarySearch.swift
// The library search AppleScript builders. Mirrors the shape of
// libraryBulkReadScript() in Sources/TUI/LibraryIndex.swift: astid saved and
// restored, a record separator to join the matched tracks' columns, one bulk
// get per column instead of a per row repeat loop. Music.app's `contains ""` is
// false for every row, so a whose clause built from an empty term or an
// empty facet would silently return zero hits; every clause here is built
// only from non-empty inputs, and no clause may ever carry an empty string.

import Foundation

/// Builds the AppleScript that filters playlist "Library" by term, artist
/// and album. term (when non-empty) matches name, artist or album; artist
/// and album (when non-empty, from --artist/--album) each add their own
/// clause; clauses are joined with "and". All three empty means no filter
/// can be built, so the selector is every track of playlist "Library" with
/// no whose clause (a caller gate stops that from reaching Music; the
/// builder must never emit a whose with nothing after it).
///
/// The whose selector is written inline on every column get and is never
/// bound to a variable. Measured live 2026-08-28 on 14,223 tracks: binding
/// the whose result (set hits to ...) turns it into a list of track
/// specifiers and "persistent ID of hits" throws "Can't make class pPIS of
/// {...}"; the inline form "persistent ID of (every track of playlist
/// "Library" whose ...)" returned 159 rows, and two columns with the full
/// three-way or clause took 0.19s, so repeating the clause per column is
/// free. A whose that matches nothing does not yield "": a column get on it
/// throws error -1728, so the script counts first and returns "" itself on
/// zero matches (parseLibrarySearchRows already treats "" as no rows).
func librarySearchScript(term: String, artist: String?, album: String?) -> String {
    var clauses: [String] = []
    if !term.isEmpty {
        let t = escapeAppleScriptString(term)
        clauses.append("(name contains \"\(t)\" or artist contains \"\(t)\" or album contains \"\(t)\")")
    }
    if let artist, !artist.isEmpty {
        clauses.append("artist contains \"\(escapeAppleScriptString(artist))\"")
    }
    if let album, !album.isEmpty {
        clauses.append("album contains \"\(escapeAppleScriptString(album))\"")
    }

    let sel: String
    if clauses.isEmpty {
        sel = "every track of playlist \"Library\""
    } else {
        sel = "every track of playlist \"Library\" whose \(clauses.joined(separator: " and "))"
    }

    return """
    set astid to AppleScript's text item delimiters
    set fs to (ASCII character 31)
    set rs to (ASCII character 30)
    if (count of (\(sel))) is 0 then return ""
    set AppleScript's text item delimiters to rs
    set ids to (persistent ID of (\(sel))) as text
    set ns to (name of (\(sel))) as text
    set ars to (artist of (\(sel))) as text
    set als to (album of (\(sel))) as text
    set aas to (album artist of (\(sel))) as text
    set AppleScript's text item delimiters to astid
    return ids & fs & ns & fs & ars & fs & als & fs & aas
    """
}

/// One track hit from a library search: five columns, no cloud status (the
/// comment above librarySearchScript already notes callers here don't need
/// it, so the row shape stays a sibling of LibraryTrackRow, not a reuse of
/// it).
struct LibrarySearchRow: Equatable {
    let persistentID: String
    let name: String
    let artist: String
    let album: String
    let albumArtist: String
}

/// Pure parse of the five column blocks into rows by position. Same rules as
/// parseLibraryTrackRows (LibraryIndex.swift): trim, split on asFieldSep,
/// require exactly five blocks, split each on asRowSep, require equal row
/// counts across all five, else []. One extra rule this parser needs that
/// the bulk read does not: when the whose clause matches nothing, each of
/// the five "as text" gets is an empty string, and joining five empty
/// strings with asFieldSep still leaves the separator characters themselves
/// in the raw payload, not a truly empty string, so splitting on asFieldSep
/// still yields five blocks and would otherwise parse as one row of empty
/// fields instead of the zero hits it actually is. So once the block and
/// row count checks pass, a raw that is nothing but separator characters is
/// treated as zero rows, not one empty row.
func parseLibrarySearchRows(_ raw: String) -> [LibrarySearchRow] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let blocks = trimmed.components(separatedBy: String(asFieldSep))
    guard blocks.count == 5 else { return [] }
    let columns = blocks.map { $0.components(separatedBy: String(asRowSep)) }
    guard let count = columns.first?.count, columns.allSatisfy({ $0.count == count }) else { return [] }
    let strippedOfSeparators = trimmed
        .replacingOccurrences(of: String(asFieldSep), with: "")
        .replacingOccurrences(of: String(asRowSep), with: "")
    guard !strippedOfSeparators.isEmpty else { return [] }
    return (0..<count).map { i in
        LibrarySearchRow(persistentID: columns[0][i], name: columns[1][i], artist: columns[2][i],
                          album: columns[3][i], albumArtist: columns[4][i])
    }
}

/// Builds the AppleScript that reads every user playlist's name. For
/// --types playlists, do not over-promise "one library track read."
/// Playlist names cannot be grouped from Library tracks; use a small
/// AppleScript playlist-name read when playlist results are requested.
/// "every user playlist" is the same class sweepQueuePlaylists enumerates
/// (PlaylistDataSources.swift line 87); subscription playlists are
/// deliberately not searched here, the REST library search never returned
/// them either, so this keeps parity with it. A possible follow-up if that
/// parity ever needs to widen.
func libraryPlaylistNamesScript() -> String {
    """
    set astid to AppleScript's text item delimiters
    set AppleScript's text item delimiters to (ASCII character 30)
    set out to (name of every user playlist) as text
    set AppleScript's text item delimiters to astid
    return out
    """
}

/// Groups a library search's raw rows into the same SearchResults shape
/// parseSearchResults builds from the REST response, so a caller can treat
/// a library search and a catalog search identically past this point. Only
/// the requested types are populated, same contract as parseSearchResults
/// (RESTAPIBackend.swift lines 265 to 279). limit caps each list
/// independently; a limit below 1 is not treated as uncapped, it caps at 1.
/// Pure.
func groupLibrarySearch(rows: [LibrarySearchRow], playlistNames: [String], term: String,
                        types: [SearchType], limit: Int) -> SearchResults {
    let cap = max(1, limit)
    var out = SearchResults()
    for type in types {
        switch type {
        case .songs:
            out.songs = rows.prefix(cap).map {
                CatalogSong(id: $0.persistentID, title: $0.name, artist: $0.artist, album: $0.album)
            }
        case .albums:
            // Same grouping rule as groupLibraryAlbums (LibraryIndex.swift
            // line 115): rows with an empty album are songs without an
            // album, not albums, and are dropped. Reusing libraryAlbumID
            // means a --library --types albums id equals the Library tab's
            // id for the same album.
            var order: [String] = []
            var names: [String: String] = [:]
            var credits: [String: String] = [:]
            for row in rows where !row.album.isEmpty {
                let key = libraryAlbumKey(album: row.album, albumArtist: row.albumArtist, artist: row.artist)
                if names[key] == nil {
                    order.append(key)
                    names[key] = row.album
                    credits[key] = row.albumArtist.isEmpty ? row.artist : row.albumArtist
                }
            }
            out.albums = order.prefix(cap).map { key in
                CatalogAlbum(id: libraryAlbumID(forKey: key), name: names[key] ?? "", artist: credits[key] ?? "")
            }
        case .artists:
            // Same credit and dedupe rule as groupLibraryArtists
            // (LibraryIndex.swift line 150): id == name, there is no other
            // id.
            var seen = Set<String>()
            var creditsInOrder: [String] = []
            for row in rows {
                let credit = row.albumArtist.isEmpty ? row.artist : row.albumArtist
                guard !credit.isEmpty, !seen.contains(credit) else { continue }
                seen.insert(credit)
                creditsInOrder.append(credit)
            }
            out.artists = creditsInOrder.prefix(cap).map { CatalogArtist(id: $0, name: $0) }
        case .playlists:
            // Playlist names carry no artist, so an empty term (only
            // --artist/--album given) matches no playlists at all.
            guard !term.isEmpty else { continue }
            out.playlists = playlistNames
                .filter { $0.range(of: term, options: .caseInsensitive) != nil }
                .filter { !isTempPlaylistName($0) }
                .prefix(cap)
                .map { CatalogPlaylist(id: $0, name: $0, curator: "") }
        }
    }
    return out
}

/// Runs a library search end to end: builds the whose-clause script, reads
/// it through AppleScript, parses the rows, optionally reads playlist names,
/// and groups into SearchResults. Impure (spawns osascript); everything it
/// calls is pure and unit-tested on its own.
///
/// hasFilter is a second guard behind librarySearchScript's own no-whose
/// builder: with no term, artist, or album to filter on there is nothing to
/// search for, so skip the track read entirely rather than pay for a full
/// unfiltered read of the whole library (0.85s for 14k tracks, vs 0.18s for
/// a filtered whose read) just to hand back `limit` of them. An unfiltered
/// "search" is not a search.
///
/// timeout: 60 matches fetchLibraryTrackRows (LibraryIndex.swift line 76):
/// margin for a Music.app that is still launching, not for the read itself.
func librarySearchResults(term: String, artist: String?, album: String?,
                          types: [SearchType], limit: Int) throws -> SearchResults {
    let wantsTracks = types.contains { $0 != .playlists }
    let hasFilter = !term.isEmpty || !(artist ?? "").isEmpty || !(album ?? "").isEmpty
    let backend = AppleScriptBackend()
    var rows: [LibrarySearchRow] = []
    if wantsTracks && hasFilter {
        let raw = try syncRun { try await backend.runMusic(librarySearchScript(term: term, artist: artist, album: album), timeout: 60) }
        rows = parseLibrarySearchRows(raw)
    }
    var names: [String] = []
    if types.contains(.playlists) {
        let raw = try syncRun { try await backend.runMusic(libraryPlaylistNamesScript()) }
        names = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: String(asRowSep)).filter { !$0.isEmpty }
    }
    return groupLibrarySearch(rows: rows, playlistNames: names, term: term, types: types, limit: limit)
}

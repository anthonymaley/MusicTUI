// tools/music/Sources/Commands/CLIBridgeReads.swift
import Foundation

/// P4 (Slice 3, Part 2): pure renderers for the Bridge-mode CLI reads —
/// catalogue search, station search, discover, playlist list/tracks, history.
///
/// Every renderer takes provider-surface types already in hand
/// (`CatalogueRecord`/`HistoryItem`, `ProviderSurfaces.swift`; `MusicRow`,
/// `MusicProvider.swift`; `DiscoverRail`/`DiscoverItem`, `DiscoverFeed.swift`;
/// `Station`, `StationPlayback.swift`) and returns text lines and/or one JSON
/// document. **No cache, no I/O, no dispatch.** Where a read also produces
/// cacheable song rows (catalogue search, playlist tracks, history), the row
/// function returns plain structs — never `SongResult`/`ResultCache` — so the
/// dispatching command (P6/P8/P9) publishes them (D3: publish, then print)
/// before calling the matching `*Lines`/`*JSON` function.
///
/// JSON follows the house style set by `cliFailureText`
/// (`CLIBridgeGate.swift`): `JSONSerialization` with `.sortedKeys`, one
/// document per command.

private func bridgeReadsJSON(_ value: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Catalogue search (D5 `slice.search`; D6 `.bridgeCatalog` provenance)

/// The row to publish to the result cache for one catalogue SONG (`.bridgeCatalog`,
/// D6) — 1-based, numbered independently of any album rows mixed into the same
/// reply (D6: only Bridge-typed songs get the origin; albums never do).
struct BridgeCatalogueSongRow: Equatable {
    let index: Int
    let title: String
    let artist: String
    /// `nil` when Bridge sent none — the caller decides how an absent album
    /// prints in a cached row; this struct never invents `""`.
    let album: String?
    let bridgeID: String
}

/// Numbers only the songs, in reply order; albums never get an index (D10:
/// "albums never cached").
func catalogueSearchSongRows(_ records: [CatalogueRecord]) -> [BridgeCatalogueSongRow] {
    var rows: [BridgeCatalogueSongRow] = []
    for r in records where r.kind == .song {
        rows.append(BridgeCatalogueSongRow(index: rows.count + 1, title: r.title, artist: r.artist,
                                           album: r.album, bridgeID: r.catalogueID))
    }
    return rows
}

/// P4: `N. Title — Artist[ [Album]] (id: <id>)` for songs, then an unnumbered
/// `Albums:` section, `  Title — Artist (id: <id>)` — the shipped shapes
/// (`SearchCommand.swift:155-162`), minus the leading blank line when there
/// are no songs, and with the album bracket omitted rather than printed empty.
func catalogueSearchLines(_ records: [CatalogueRecord]) -> [String] {
    let songs = records.filter { $0.kind == .song }
    let albums = records.filter { $0.kind == .album }
    var lines: [String] = []
    for (i, s) in songs.enumerated() {
        let album = s.album.map { " [\($0)]" } ?? ""
        lines.append("\(i + 1). \(s.title) — \(s.artist)\(album) (id: \(s.catalogueID))")
    }
    if !albums.isEmpty {
        lines.append(songs.isEmpty ? "Albums:" : "\nAlbums:")
        for a in albums {
            lines.append("  \(a.title) — \(a.artist) (id: \(a.catalogueID))")
        }
    }
    return lines
}

/// P4: songs-only replies print as a bare array of `{"id","title","artist","album"?}`
/// (album absent, never `""`); a mixed reply becomes an object keyed by
/// `songs`/`albums`, each key present only when that kind is non-empty (the
/// shipped multi-type shape, `SearchCommand.swift:77-84`).
func catalogueSearchJSON(_ records: [CatalogueRecord], songsOnlyRequest: Bool = true) -> String {
    let songs = records.filter { $0.kind == .song }
    let albums = records.filter { $0.kind == .album }
    func songDict(_ r: CatalogueRecord) -> [String: Any] {
        var d: [String: Any] = ["id": r.catalogueID, "title": r.title, "artist": r.artist]
        if let album = r.album { d["album"] = album }
        return d
    }
    func albumDict(_ r: CatalogueRecord) -> [String: Any] {
        ["id": r.catalogueID, "title": r.title, "artist": r.artist]
    }
    // The shape follows what was ASKED for, as the shipped body does: a bare
    // array only for a songs-only request, even when a mixed request finds no albums.
    if songsOnlyRequest {
        return bridgeReadsJSON(songs.map(songDict))
    }
    var payload: [String: Any] = [:]
    if !albums.isEmpty { payload["albums"] = albums.map(albumDict) }
    if !songs.isEmpty { payload["songs"] = songs.map(songDict) }
    return bridgeReadsJSON(payload)
}

// MARK: - Station search (D5 `slice.searchStations`; the shipped RadioSearch lines)

/// P4: exactly `RadioSearch.run()`'s shipped lines (`RadioCommands.swift:97-113`) —
/// `Name  [LIVE]` (suffix only when `isLive == true`) then an indented URL line,
/// one pair per station; empty is the shipped "shallow search" sentence.
func stationSearchLines(_ stations: [Station]) -> [String] {
    guard !stations.isEmpty else {
        return ["No stations found. Station search is shallow — pasting the URL always works."]
    }
    return stations.map { s in
        "\(s.name)\(s.isLive == true ? "  [LIVE]" : "")\n  \(s.url)"
    }
}

// MARK: - Discover (D5 `slice.recommendations`/`slice.containerTracks`)

private func discoverItemLine(_ item: DiscoverItem) -> String {
    let playable = item.kind == .station ? "▶ " : "  "
    let subtitle = item.subtitle.map { " — \($0)" } ?? ""
    return "\(playable)\(item.name)\(subtitle)  [\(discoverKindLabel(item.kind))]"
}

private func discoverKindLabel(_ kind: DiscoverItemKind) -> String {
    switch kind {
    case .station: return "station"
    case .album: return "album"
    case .playlist: return "playlist"
    case .song: return "song"
    }
}

/// P4: the shipped `Discover.line(_:)` text (`DiscoverCommands.swift:66-70,83-87`):
/// a blank line then the rail title, then each item indented two spaces.
func bridgeDiscoverLines(_ rails: [DiscoverRail]) -> [String] {
    var lines: [String] = []
    for rail in rails {
        lines.append("\n\(rail.title)")
        for item in rail.items {
            lines.append("  " + discoverItemLine(item))
        }
    }
    return lines
}

private func discoverItemDict(_ item: DiscoverItem) -> [String: Any] {
    var d: [String: Any] = ["name": item.name, "kind": discoverKindLabel(item.kind), "id": item.id]
    if let subtitle = item.subtitle { d["subtitle"] = subtitle }
    if let artwork = item.artworkURL { d["artwork"] = artwork }
    return d
}

/// P4/D5: the shipped rail/item dicts (`DiscoverCommands.swift:56-60,89-95`)
/// MINUS `recentlyPlayed` and `url` — Bridge sends neither (D5), so they are
/// never printed, not even as `false`/empty.
func bridgeDiscoverJSON(_ rails: [DiscoverRail]) -> String {
    let payload = rails.map { rail -> [String: Any] in
        ["title": rail.title, "items": rail.items.map(discoverItemDict)]
    }
    return bridgeReadsJSON(payload)
}

// MARK: - Playlist list (D5 `slice.libraryPlaylists`)

/// P4: names only, one per line, in reply order — the shipped `listPlaylists`
/// text (`PlaylistCommands.swift:60`).
func playlistListLines(_ playlists: [MusicRow]) -> [String] {
    playlists.map { $0.title }
}

/// P4: `{"playlists":[{"name","bridge_id"}]}` — no `id` key, so a Bridge
/// playlist id can never be mistaken for a Music.app or REST one.
func playlistListJSON(_ playlists: [MusicRow]) -> String {
    let payload: [String: Any] = ["playlists": playlists.map { ["name": $0.title, "bridge_id": $0.id] }]
    return bridgeReadsJSON(payload)
}

// MARK: - Playlist tracks (D5 `slice.libraryPlaylistTracks`)

/// The row to publish for one playlist track (`.bridgeLibrary`), 1-based in
/// reply order.
struct BridgePlaylistTrackRow: Equatable {
    let index: Int
    let title: String
    let artist: String
    let album: String?
    let bridgeID: String
}

func playlistTrackSongRows(_ tracks: [MusicRow]) -> [BridgePlaylistTrackRow] {
    tracks.enumerated().map { i, t in
        BridgePlaylistTrackRow(index: i + 1, title: t.title, artist: t.artist, album: t.album, bridgeID: t.id)
    }
}

/// P4: `N. Title — Artist [Album]` — the shipped playlist-tracks line
/// (`PlaylistCommands.swift:133-134,175-176`); the bracket is always printed,
/// empty when Bridge sent no album (unlike catalogue search's optional bracket).
func playlistTracksLines(_ tracks: [MusicRow]) -> [String] {
    playlistTrackSongRows(tracks).map { row in
        "\(row.index). \(row.title) — \(row.artist) [\(row.album ?? "")]"
    }
}

/// P4: `{"playlist","tracks":[{"number","track","artist","album"?,"bridge_id"}]}` —
/// `album` present only when Bridge sent one, never `""`.
func playlistTracksJSON(playlist: String, tracks: [MusicRow]) -> String {
    let rows = playlistTrackSongRows(tracks)
    let payload: [String: Any] = ["playlist": playlist, "tracks": rows.map { row -> [String: Any] in
        var d: [String: Any] = ["number": row.index, "track": row.title, "artist": row.artist,
                                "bridge_id": row.bridgeID]
        if let album = row.album { d["album"] = album }
        return d
    }]
    return bridgeReadsJSON(payload)
}

// MARK: - History (D5 `slice.recentTracks`/`slice.heavyRotation`)

/// The row to publish for one history SONG that carries a catalogue id
/// (`.bridgeCatalog`, D6, D10 "numbered items only"). A library-only song (no
/// `catalogueID`) is rendered but never published — it has no Bridge-owned
/// catalogue identity to play by.
struct BridgeHistorySongRow: Equatable {
    let index: Int
    let title: String
    let artist: String
    let album: String
    let catalogueID: String
}

/// Numbers only songs that carry a `catalogueID`, in reply order — a
/// library-only song or a non-song item is skipped, never given a number.
func historySongRows(_ items: [HistoryItem]) -> [BridgeHistorySongRow] {
    var rows: [BridgeHistorySongRow] = []
    for item in items where item.type.contains("song") {
        guard let catalogueID = item.catalogueID, !catalogueID.isEmpty else { continue }
        rows.append(BridgeHistorySongRow(index: rows.count + 1, title: item.name,
                                         artist: item.artist ?? "", album: item.album ?? "",
                                         catalogueID: catalogueID))
    }
    return rows
}

private func historyKindLabel(_ type: String) -> String {
    var s = type
    if s.hasPrefix("library-") { s.removeFirst("library-".count) }
    if s.hasSuffix("s") { s.removeLast() }
    return s
}

/// P4: a song with a `catalogueID` is numbered, `N. Name — Artist[ [Album]]`;
/// a song without one is unnumbered, `   Name[ — Artist] (library)`; any other
/// type is unnumbered, `   Name[ — Artist] (<kind>)` — the shipped shapes and
/// kind-stripping (`HistoryCommands.swift:93,95-96`). Numbering counts only the
/// numbered rows. Empty prints the shipped `No <label> history.`.
func historyLines(_ items: [HistoryItem], label: String) -> [String] {
    guard !items.isEmpty else { return ["No \(label) history."] }
    var lines: [String] = []
    var n = 0
    for item in items {
        let isSong = item.type.contains("song")
        if isSong, let catalogueID = item.catalogueID, !catalogueID.isEmpty {
            n += 1
            let album = item.album.map { " [\($0)]" } ?? ""
            lines.append("\(n). \(item.name) — \(item.artist ?? "")\(album)")
        } else {
            let artist = item.artist.map { " — \($0)" } ?? ""
            let kind = isSong ? "library" : historyKindLabel(item.type)
            lines.append("   \(item.name)\(artist) (\(kind))")
        }
    }
    return lines
}

/// P4: `{"items":[{"type","name","artist","album"}]}` — as shipped, `artist`
/// and `album` keys always present, `""` when absent (unlike catalogue search
/// and playlist tracks, where an absent album key is omitted). Empty prints
/// the shipped `{"<label-with-dashes>":[]}`.
func historyJSON(_ items: [HistoryItem], label: String) -> String {
    guard !items.isEmpty else {
        let key = label.replacingOccurrences(of: " ", with: "-")
        return bridgeReadsJSON([key: [] as [Any]])
    }
    let dicts = items.map { item -> [String: Any] in
        ["type": item.type, "name": item.name, "artist": item.artist ?? "", "album": item.album ?? ""]
    }
    return bridgeReadsJSON(["items": dicts])
}

// tools/music/Sources/Commands/CLIBridgeSelection.swift
//
// S4: D4's name-and-play resolution for `music play --playlist/--album/
// --artist/--song` and `music search --library`, entirely against Bridge's
// own library. **No command wiring** — this file never touches
// `PlaybackCommands.swift`, `CLIBridgeEnv`, `ActionRouting.swift` or the
// output lock, and it never calls `control.queue`/`slice.queue`: it only
// reads `slice.library*` and hands back ids for S7 to send. A genuine
// provider failure (an unreadable reply, a warming budget spent, two stale
// generations in a row) is thrown as a `MusicProviderError`, the same way
// every other Bridge read fails, and is left to the caller's D5 failure line
// — `.refused` below is reserved for the pure name-matching outcomes.

import Foundation

/// What resolving a playlist/album/artist/song name comes to: something to
/// queue, or a refusal to show verbatim.
enum BridgeSelection: Equatable {
    /// `label` is the matched row's own name, for the caller's D5 message;
    /// `ids` are Bridge library ids already in queue order (shuffled or
    /// not, per D4); `startRequired` and `skippedVideos` are D4's per-form
    /// values (0 for every form but playlists).
    case play(label: String, ids: [String], startRequired: Bool, skippedVideos: Int)
    case refused(String)
}

/// D4's name rule, exact-then-unique-substring, both sides folded through
/// `normalizeAlbumTitle` — title identity, the same function `--album`
/// matching already uses, deliberately not `normalizeCredit` (a row's own
/// name is not a credit). Never picks first: one exact match plays; two or
/// more is ambiguous; failing that, one substring match plays; two or more
/// is ambiguous; zero is not found. Pure.
enum RowNameMatch: Equatable {
    case one(MusicRow)
    case ambiguous([MusicRow])
    case notFound
}

func matchRowsByName(_ rows: [MusicRow], query: String) -> RowNameMatch {
    let q = normalizeAlbumTitle(query)
    let exact = rows.filter { normalizeAlbumTitle($0.title) == q }
    if exact.count == 1 { return .one(exact[0]) }
    if exact.count > 1 { return .ambiguous(exact) }
    let substring = rows.filter { normalizeAlbumTitle($0.title).contains(q) }
    if substring.count == 1 { return .one(substring[0]) }
    if substring.count > 1 { return .ambiguous(substring) }
    return .notFound
}

/// D4's artist filter — `normalizeCredit(row.artist).contains(normalizeCredit(a))`
/// — applied to narrow rows BEFORE `matchRowsByName` runs on the title. A nil
/// or empty artist is no filter at all. Pure.
func filterRowsByArtist(_ rows: [MusicRow], artist: String?) -> [MusicRow] {
    guard let artist, !artist.isEmpty else { return rows }
    let a = normalizeCredit(artist)
    return rows.filter { normalizeCredit($0.artist).contains(a) }
}

// MARK: - Refusals (verbatim, S4)

private func bridgeNotFoundMessage(kind: String, query: String) -> String {
    "No \(kind) named '\(query)' in your Bridge library."
}

private func bridgeSongNotFoundMessage(title: String, artist: String?) -> String {
    var msg = "No song matching '\(title)'"
    if let artist, !artist.isEmpty { msg += " by '\(artist)'" }
    msg += " in your Bridge library. From the CLI, Bridge plays your library only; nothing was added or played."
    return msg
}

private func bridgeNoSongsMessage(name: String) -> String {
    "'\(name)' has no songs Bridge can play."
}

/// `kindPlural` is the plain plural noun ("playlists", "albums", "artists",
/// "songs"); `suggestArtist` adds the `--artist` hint (album, song, never
/// playlist or artist); `songHint` appends the `search --library` redirect
/// (song only).
private func bridgeAmbiguousMessage(query: String, kindPlural: String, rows: [MusicRow],
                                    suggestArtist: Bool, songHint: Bool) -> String {
    let shown = rows.prefix(5).map { "\($0.title) — \($0.artist)" }.joined(separator: "; ")
    var msg = "'\(query)' matches \(rows.count) \(kindPlural) in your Bridge library: \(shown)"
    if rows.count > 5 { msg += "; and \(rows.count - 5) more" }
    msg += suggestArtist ? ". Use the exact name, or add --artist." : ". Use the exact name."
    if songHint {
        msg += " Or: music search --library \"\(query)\"  then  music play N"
    }
    return msg
}

// MARK: - Resolvers (provider, …, budget, sleep, onWarming)
//
// Each resolver shares ONE `WarmUpBudget` across its whole action — the
// container list walk and, on a single match, the tracks read that follows —
// per `walkLibraryPages(budget:)`'s own doc: a caller-owned budget is right
// for a PLAY, not a fresh one per page. `budget`'s default is evaluated at
// each call site, so a caller that does not pass one still gets its own.

/// `--playlist NAME [shuffle]`. Temp playlists (`isTempPlaylistName`) are
/// dropped before matching, so they can neither match nor count toward an
/// ambiguity. `startRequired` is always false (D4): a whole-playlist play
/// never claims a specific track was chosen.
func resolveBridgePlaylistSelection(provider: MusicDataProvider, name: String, shuffle: Bool,
                                    budget: WarmUpBudget = WarmUpBudget(),
                                    sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                    onWarming: @escaping (TimeInterval) -> Void = { _ in }) throws -> BridgeSelection {
    var rows: [MusicRow] = []
    if let error = walkLibraryPages(fetch: provider.libraryPlaylists,
                                    onPage: { page in rows.append(contentsOf: page.rows); return true },
                                    onRestart: { rows = [] }, onWarming: onWarming, sleep: sleep, budget: budget) {
        throw error
    }
    let visible = rows.filter { !isTempPlaylistName($0.title) }
    switch matchRowsByName(visible, query: name) {
    case .notFound:
        return .refused(bridgeNotFoundMessage(kind: "playlist", query: name))
    case .ambiguous(let matches):
        return .refused(bridgeAmbiguousMessage(query: name, kindPlural: "playlists", rows: matches,
                                               suggestArtist: false, songHint: false))
    case .one(let row):
        var trackRows: [MusicRow] = []
        // Bridge's `skipped_videos` is the WHOLE playlist's count, restated on
        // every page (not a per-page increment) — the same convention
        // `playBridgePlaylist` (PlaylistsScene.swift) already follows, so the
        // last page's value is kept rather than summed.
        var skippedVideos = 0
        if let error = walkLibraryPages(
            fetch: { cursor, limit in try provider.playlistTracks(playlistID: row.id, cursor: cursor, limit: limit) },
            limit: 500,
            onPage: { page in trackRows.append(contentsOf: page.rows); skippedVideos = page.skippedVideos; return true },
            onRestart: { trackRows = []; skippedVideos = 0 },
            onWarming: onWarming, sleep: sleep, budget: budget) {
            throw error
        }
        guard !trackRows.isEmpty else { return .refused(bridgeNoSongsMessage(name: row.title)) }
        let ids = bridgeQueueIDs(trackRows, shuffle: shuffle, startAt: 1)
        return .play(label: row.title, ids: ids, startRequired: false, skippedVideos: skippedVideos)
    }
}

/// `--album NAME [--artist A] [shuffle]`. `startRequired` is always false.
func resolveBridgeAlbumSelection(provider: MusicDataProvider, name: String, artist: String?, shuffle: Bool,
                                 budget: WarmUpBudget = WarmUpBudget(),
                                 sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                 onWarming: @escaping (TimeInterval) -> Void = { _ in }) throws -> BridgeSelection {
    var rows: [MusicRow] = []
    if let error = walkLibraryPages(fetch: provider.libraryAlbums,
                                    onPage: { page in rows.append(contentsOf: page.rows); return true },
                                    onRestart: { rows = [] }, onWarming: onWarming, sleep: sleep, budget: budget) {
        throw error
    }
    let filtered = filterRowsByArtist(rows, artist: artist)
    switch matchRowsByName(filtered, query: name) {
    case .notFound:
        return .refused(bridgeNotFoundMessage(kind: "album", query: name))
    case .ambiguous(let matches):
        return .refused(bridgeAmbiguousMessage(query: name, kindPlural: "albums", rows: matches,
                                               suggestArtist: true, songHint: false))
    case .one(let row):
        let list = try retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: sleep) {
            try provider.albumTracks(albumID: row.id)
        }
        guard !list.rows.isEmpty else { return .refused(bridgeNoSongsMessage(name: row.title)) }
        let ids = bridgeQueueIDs(list.rows, shuffle: shuffle, startAt: 1)
        return .play(label: row.title, ids: ids, startRequired: false, skippedVideos: 0)
    }
}

/// `--artist NAME`. Plays in Bridge's own order (never shuffled — D4 takes
/// no `shuffle` word for this form), `startRequired` false.
func resolveBridgeArtistSelection(provider: MusicDataProvider, name: String,
                                  budget: WarmUpBudget = WarmUpBudget(),
                                  sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                  onWarming: @escaping (TimeInterval) -> Void = { _ in }) throws -> BridgeSelection {
    var rows: [MusicRow] = []
    if let error = walkLibraryPages(fetch: provider.libraryArtists,
                                    onPage: { page in rows.append(contentsOf: page.rows); return true },
                                    onRestart: { rows = [] }, onWarming: onWarming, sleep: sleep, budget: budget) {
        throw error
    }
    switch matchRowsByName(rows, query: name) {
    case .notFound:
        return .refused(bridgeNotFoundMessage(kind: "artist", query: name))
    case .ambiguous(let matches):
        return .refused(bridgeAmbiguousMessage(query: name, kindPlural: "artists", rows: matches,
                                               suggestArtist: false, songHint: false))
    case .one(let row):
        let list = try retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: sleep) {
            try provider.artistSongs(artistID: row.id)
        }
        guard !list.rows.isEmpty else { return .refused(bridgeNoSongsMessage(name: row.title)) }
        return .play(label: row.title, ids: list.rows.map(\.id), startRequired: false, skippedVideos: 0)
    }
}

/// `--song T [--artist A]`. One id, `startRequired` true (D4: the person
/// picked this exact song). No catalogue fallback and no shuffle.
func resolveBridgeSongSelection(provider: MusicDataProvider, title: String, artist: String?,
                                budget: WarmUpBudget = WarmUpBudget(),
                                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                onWarming: @escaping (TimeInterval) -> Void = { _ in }) throws -> BridgeSelection {
    var rows: [MusicRow] = []
    if let error = walkLibraryPages(fetch: provider.librarySongs,
                                    onPage: { page in rows.append(contentsOf: page.rows); return true },
                                    onRestart: { rows = [] }, onWarming: onWarming, sleep: sleep, budget: budget) {
        throw error
    }
    let filtered = filterRowsByArtist(rows, artist: artist)
    switch matchRowsByName(filtered, query: title) {
    case .notFound:
        return .refused(bridgeSongNotFoundMessage(title: title, artist: artist))
    case .ambiguous(let matches):
        return .refused(bridgeAmbiguousMessage(query: title, kindPlural: "songs", rows: matches,
                                               suggestArtist: true, songHint: true))
    case .one(let row):
        return .play(label: row.title, ids: [row.id], startRequired: true, skippedVideos: 0)
    }
}

// MARK: - search --library (D4)

/// What `bridgeLibrarySearch` found, or the one refusal that precedes any
/// Bridge request at all.
enum BridgeLibrarySearchResult: Equatable {
    case rows([MusicRow])
    case refused(String)
}

/// Mirrors `librarySearchScript`'s own clauses — term matches title, artist
/// or album; `--artist`/`--album` each add an AND'd clause; all three blank
/// refuses before any Bridge request is made — but runs them against a
/// Bridge `slice.librarySongs` walk instead of an AppleScript `whose` read.
/// Bridge's own order is kept; the caller (S7) publishes and numbers the
/// first `limit` matches.
func bridgeLibrarySearch(provider: MusicDataProvider, term: String, artist: String?, album: String?,
                         limit: Int,
                         budget: WarmUpBudget = WarmUpBudget(),
                         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                         onWarming: @escaping (TimeInterval) -> Void = { _ in }) throws -> BridgeLibrarySearchResult {
    let hasFilter = !term.isEmpty || !(artist ?? "").isEmpty || !(album ?? "").isEmpty
    guard hasFilter else { return .refused("Name something to search for.") }

    var rows: [MusicRow] = []
    if let error = walkLibraryPages(fetch: provider.librarySongs,
                                    onPage: { page in rows.append(contentsOf: page.rows); return true },
                                    onRestart: { rows = [] }, onWarming: onWarming, sleep: sleep, budget: budget) {
        throw error
    }

    let matches = rows.filter { row in
        if !term.isEmpty,
           !containsCaseInsensitive(row.title, term),
           !containsCaseInsensitive(row.artist, term),
           !containsCaseInsensitive(row.album ?? "", term) {
            return false
        }
        if let artist, !artist.isEmpty, !containsCaseInsensitive(row.artist, artist) { return false }
        if let album, !album.isEmpty, !containsCaseInsensitive(row.album ?? "", album) { return false }
        return true
    }
    return .rows(Array(matches.prefix(max(0, limit))))
}

private func containsCaseInsensitive(_ haystack: String, _ needle: String) -> Bool {
    haystack.range(of: needle, options: .caseInsensitive) != nil
}

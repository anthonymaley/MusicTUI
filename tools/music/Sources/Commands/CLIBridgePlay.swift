// tools/music/Sources/Commands/CLIBridgePlay.swift
//
// The Bridge branch of `music play` (slice 3 score, S7; decisions D2, D4, D5).
// It runs inside `cliDispatch`'s `.source` branch, after readiness, with the
// command's one `CLIBridgeSession`.
//
// **Order (S7).** Refusals that need no library read come first
// (`artistWithLooseWordsRefusal`, one selection flag, D4's lone `shuffle`, a
// blank name); then the name is resolved against Bridge's library (S4,
// OUTSIDE the output lock); then the ids are built; only then is the one
// mutation sent through `session.mutate` (the lock, revalidation, and a retry
// of a pre-mutation `warming` only); then the status is observed (D5), and a
// failed observation never re-sends anything.
//
// The named forms play from Bridge's own library. Catalogue playback (Part 2
// P6, D6/D7) is two forms only: `play N` on a `.bridgeCatalog` row (through
// `bridgeRef`) and a one-arg Apple Music SONG link, each queued as catalogue
// ids with `slice.queue {"ids"}`. Free words, and any link that is not a song
// link (which classifies as words), never reach this file: the matrix refuses
// them. These plays are not recorded in Music.app's play counts; library
// attribution is Part C's.
import ArgumentParser
import Foundation

// MARK: - Which form, in Play's branch order

/// One `music play` invocation, classified in the shipped command's branch
/// order: `--playlist`, `--album`, `--song`, `--artist` (alone, or with loose
/// words, which both bodies refuse the same way), a one-arg Apple Music link,
/// a one-arg integer, other words, nothing.
enum PlayForm: Equatable {
    case playlist(String)
    case album(String)
    case song(String)
    case artist(String)
    case catalogLink
    case index(Int)
    case words
    case resume

    init(args: [String], playlist: String?, album: String?, song: String?, artist: String?) {
        if let playlist { self = .playlist(playlist); return }
        if let album { self = .album(album); return }
        if let song { self = .song(song); return }
        if let artist { self = .artist(artist); return }
        if args.count == 1, appleMusicSongID(from: args[0]) != nil { self = .catalogLink; return }
        if args.count == 1, let index = Int(args[0]) { self = .index(index); return }
        self = args.isEmpty ? .resume : .words
    }

    var action: MusicTUIAction {
        switch self {
        case .playlist:    return .cliPlayPlaylist
        case .album:       return .cliPlayAlbum
        case .song:        return .cliPlaySong
        case .artist:      return .cliPlayArtist
        case .catalogLink: return .cliPlayCatalogSong
        case .index:       return .cliPlayIndex
        case .words:       return .cliPlayQuery
        case .resume:      return .cliPlayResume
        }
    }
}

/// The matrix action for a `music play` invocation (D7).
func playAction(args: [String], playlist: String?, album: String?, song: String?, artist: String?) -> MusicTUIAction {
    PlayForm(args: args, playlist: playlist, album: album, song: song, artist: artist).action
}

// MARK: - Refusals (S7, verbatim)

let bridgePlayOneSelectionRefusal = "Name one of --playlist, --album, --song or --artist."

func bridgePlayExtraWordsRefusal(flag: String) -> String {
    "--\(flag) can't be combined with other words on Bridge."
}

// MARK: - The Bridge body

/// `music play` with Bridge selected.
func bridgePlayCommand(_ session: CLIBridgeSession, args: [String], playlist: String?, album: String?,
                       song: String?, artist: String?, json: Bool, env: CLIBridgeEnv) throws {
    if let refusal = artistWithLooseWordsRefusal(artist: artist, args: args,
                                                 song: song, album: album, playlist: playlist) {
        throw ActionError(message: refusal)
    }
    let named = [playlist, album, song, artist].compactMap { $0 }.count
    let artistNarrowsOne = named == 2 && artist != nil && (album != nil || song != nil)
    guard named <= 1 || artistNarrowsOne else {
        throw ActionError(message: bridgePlayOneSelectionRefusal)
    }

    let onWarming: (TimeInterval) -> Void = { _ in env.err(cliBridgeWarmingProgress) }
    let selection: BridgeSelection
    let kind: BridgePlayResultKind
    var shuffle = false

    switch PlayForm(args: args, playlist: playlist, album: album, song: song, artist: artist) {
    case .playlist(let name):
        shuffle = try bridgeLoneShuffle(args, flag: "playlist")
        try refuseBlank(name, "Playlist")
        selection = try resolveBridgePlaylistSelection(provider: session.provider, name: name, shuffle: shuffle,
                                                       budget: session.budget, sleep: env.sleep, onWarming: onWarming)
        kind = .playlist
    case .album(let name):
        shuffle = try bridgeLoneShuffle(args, flag: "album")
        try refuseBlank(name, "Album")
        selection = try resolveBridgeAlbumSelection(provider: session.provider, name: name, artist: artist,
                                                    shuffle: shuffle, budget: session.budget,
                                                    sleep: env.sleep, onWarming: onWarming)
        kind = .album
    case .song(let title):
        guard args.isEmpty else { throw ActionError(message: bridgePlayExtraWordsRefusal(flag: "song")) }
        try refuseBlank(title, "Song")
        selection = try resolveBridgeSongSelection(provider: session.provider, title: title, artist: artist,
                                                   budget: session.budget, sleep: env.sleep, onWarming: onWarming)
        kind = .song
    case .artist(let name):
        // Loose words were refused above, in the shipped words.
        try refuseBlank(name, "Artist")
        selection = try resolveBridgeArtistSelection(provider: session.provider, name: name,
                                                     budget: session.budget, sleep: env.sleep, onWarming: onWarming)
        kind = .artist
    case .index(let index):
        try bridgePlayIndex(session, index: index, json: json, env: env)
        return
    case .resume:
        _ = try session.mutate { try sendBridgeRef(.resume, to: $0) }
        bridgeShowAfterMutation(session, json: json, env: env)
        return
    case .catalogLink:
        try bridgePlaySongLink(session, link: args[0], json: json, env: env)
        return
    case .words:
        // The matrix refuses these before any Bridge request; if the route
        // ever changed without a body, refuse rather than guess.
        throw ActionError(message: cliBridgeNotServedReason(playAction(args: args, playlist: playlist, album: album,
                                                                       song: song, artist: artist)))
    }

    switch selection {
    case .refused(let why):
        throw ActionError(message: why)
    case .play(let label, let ids, let startRequired, let skippedVideos):
        // The ids were built by the resolver (shuffled or in order) BEFORE
        // this mutation; nothing is computed under the lock.
        let skipped = try session.mutate {
            try sendBridgeRef(.libraryQueue(ids: ids, startRequired: startRequired), to: $0)
        }
        bridgeShowAfterMutation(
            session, json: json, env: env,
            resultLines: bridgePlayResultLines(kind: kind, label: label, sent: ids.count,
                                               skippedUnavailable: skipped, skippedVideos: skippedVideos,
                                               shuffle: shuffle),
            resultJSON: bridgePlayResultJSON(kind: kind, sent: ids.count,
                                             skippedUnavailable: skipped, skippedVideos: skippedVideos))
    }
}

/// `music play N` with Bridge selected: the cache is read once, the row
/// becomes a reference only through `bridgeRef` (D3), then it is queued.
private func bridgePlayIndex(_ session: CLIBridgeSession, index: Int, json: Bool, env: CLIBridgeEnv) throws {
    let row = try ResultCache.row(index: index, in: env.cache.readSongs())
    switch bridgeRef(forCachedRow: row, index: index) {
    case .refuse(let why):
        throw ActionError(message: why)
    case .queue(let ref):
        let sent: Int
        switch ref {
        case .resume:                          sent = 0
        case .libraryQueue(let ids, _):        sent = ids.count
        case .catalogueQueue(let ids):         sent = ids.count
        }
        let skipped = try session.mutate { try sendBridgeRef(ref, to: $0) }
        bridgeShowAfterMutation(
            session, json: json, env: env,
            resultLines: bridgePlayResultLines(kind: .song, label: row.title, sent: sent,
                                               skippedUnavailable: skipped, skippedVideos: 0, shuffle: false),
            resultJSON: bridgePlayResultJSON(kind: .song, sent: sent, skippedUnavailable: skipped, skippedVideos: 0))
    }
}

/// `music play <Apple Music song link>` with Bridge selected (Part 2 D7): the
/// link's song id (`appleMusicSongID`, the `?i=` item, as the Music.app body
/// reads it) is queued as a catalogue id. No read precedes the mutation.
private func bridgePlaySongLink(_ session: CLIBridgeSession, link: String, json: Bool, env: CLIBridgeEnv) throws {
    guard let id = appleMusicSongID(from: link) else {
        // `PlayForm` classified this as a song link; refuse rather than guess.
        throw ActionError(message: cliBridgeNotServedReason(.cliPlayQuery))
    }
    let ref = BridgePlaybackRef.catalogueQueue(ids: [id])
    let skipped = try session.mutate { try sendBridgeRef(ref, to: $0) }
    bridgeShowAfterMutation(
        session, json: json, env: env,
        resultLines: ["Playing Apple Music song \(id) on Bridge."],
        resultJSON: bridgePlayResultJSON(kind: .song, sent: 1, skippedUnavailable: skipped, skippedVideos: 0))
}

/// D2: the one place a `BridgePlaybackRef` becomes a request. Returns Bridge's
/// `skipped_unavailable` count (0 for a resume). Exhaustive, so a new ref case
/// cannot be sent without deciding how.
func sendBridgeRef(_ ref: BridgePlaybackRef, to control: SourceControlling) throws -> Int {
    switch ref {
    case .resume:
        try control.resume()
        return 0
    case .libraryQueue(let ids, let startRequired):
        return try control.queue(libraryIDs: ids, startRequired: startRequired)
    case .catalogueQueue(let ids):
        // `slice.queue {"ids"}`: never `library_ids` (D6).
        return try control.queueReportingSkips(catalogIDs: ids)
    }
}

/// D4: after `--playlist` or `--album` the only extra word accepted is one
/// trailing `shuffle`. Returns whether it was given.
private func bridgeLoneShuffle(_ args: [String], flag: String) throws -> Bool {
    if args.isEmpty { return false }
    if args.count == 1, args[0].lowercased() == "shuffle" { return true }
    throw ActionError(message: bridgePlayExtraWordsRefusal(flag: flag))
}

/// A blank name would match every row as a substring; refuse it before any
/// library read, as the shipped `--album` does (`isBlankAlbumQuery`).
private func refuseBlank(_ name: String, _ what: String) throws {
    if isBlankAlbumQuery(name) { throw ActionError(message: "\(what) name can't be empty.") }
}

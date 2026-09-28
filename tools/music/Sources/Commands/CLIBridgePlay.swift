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
    "--\(flag) can't be combined with other words on SpanDAC."
}

// MARK: - The Bridge body

/// `music play` with Bridge selected.
func bridgePlayCommand(_ session: CLIBridgeSession, args: [String], playlist: String?, album: String?,
                       song: String?, artist: String?, json: Bool, env: CLIBridgeEnv) throws {
    let form = PlayForm(args: args, playlist: playlist, album: album, song: song, artist: artist)
    switch form {
    case .index(let index):
        try refuseNamedFormMisuse(args: args, playlist: playlist, album: album, song: song, artist: artist)
        try bridgePlayIndex(session, index: index, json: json, env: env)
        return
    case .resume:
        try refuseNamedFormMisuse(args: args, playlist: playlist, album: album, song: song, artist: artist)
        _ = try session.mutate { try sendBridgeRef(.resume, to: $0) }
        bridgeShowAfterMutation(session, json: json, env: env)
        return
    case .catalogLink:
        try refuseNamedFormMisuse(args: args, playlist: playlist, album: album, song: song, artist: artist)
        try bridgePlaySongLink(session, link: args[0], json: json, env: env)
        return
    case .words:
        try refuseNamedFormMisuse(args: args, playlist: playlist, album: album, song: song, artist: artist)
        // The matrix refuses these before any Bridge request; if the route
        // ever changed without a body, refuse rather than guess.
        throw ActionError(message: cliBridgeNotServedReason(form.action))
    case .playlist, .album, .song, .artist:
        break
    }

    let named = try resolveNamedPlay(session, args: args, playlist: playlist, album: album, song: song,
                                     artist: artist, env: env)
    switch named.selection.ids(shuffle: named.shuffle) {
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
            resultLines: bridgePlayResultLines(kind: named.kind, label: label, sent: ids.count,
                                               skippedUnavailable: skipped, skippedVideos: skippedVideos,
                                               shuffle: named.shuffle),
            resultJSON: bridgePlayResultJSON(kind: named.kind, sent: ids.count,
                                             skippedUnavailable: skipped, skippedVideos: skippedVideos))
    }
}

/// The refusals every form checks before anything else (S7's order):
/// `--artist` with loose words, and more than one selection flag.
private func refuseNamedFormMisuse(args: [String], playlist: String?, album: String?,
                                   song: String?, artist: String?) throws {
    if let refusal = artistWithLooseWordsRefusal(artist: artist, args: args,
                                                 song: song, album: album, playlist: playlist) {
        throw ActionError(message: refusal)
    }
    let named = [playlist, album, song, artist].compactMap { $0 }.count
    let artistNarrowsOne = named == 2 && artist != nil && (album != nil || song != nil)
    guard named <= 1 || artistNarrowsOne else {
        throw ActionError(message: bridgePlayOneSelectionRefusal)
    }
}

/// A named `music play` form, resolved against SpanDAC's library: the rows,
/// which form asked, and D4's lone `shuffle`.
private struct NamedPlay {
    let selection: BridgeRowSelection
    let kind: BridgePlayResultKind
    let shuffle: Bool
}

/// D4's name-and-play resolution for `--playlist/--album/--song/--artist`,
/// shared by a SpanDAC output (which queues ids) and the MusicTUI output with
/// SpanDAC data (which plays rows). Reads only, through `session.provider`,
/// with the session's one warm-up budget; never mutates.
private func resolveNamedPlay(_ session: CLIBridgeSession, args: [String], playlist: String?,
                              album: String?, song: String?, artist: String?,
                              env: CLIBridgeEnv) throws -> NamedPlay {
    try refuseNamedFormMisuse(args: args, playlist: playlist, album: album, song: song, artist: artist)
    let onWarming: (TimeInterval) -> Void = { _ in env.err(cliBridgeWarmingProgress) }
    switch PlayForm(args: args, playlist: playlist, album: album, song: song, artist: artist) {
    case .playlist(let name):
        let shuffle = try bridgeLoneShuffle(args, flag: "playlist")
        try refuseBlank(name, "Playlist")
        return NamedPlay(selection: try resolveBridgePlaylistRows(provider: session.provider, name: name,
                                                                  budget: session.budget, sleep: env.sleep,
                                                                  onWarming: onWarming),
                         kind: .playlist, shuffle: shuffle)
    case .album(let name):
        let shuffle = try bridgeLoneShuffle(args, flag: "album")
        try refuseBlank(name, "Album")
        return NamedPlay(selection: try resolveBridgeAlbumRows(provider: session.provider, name: name,
                                                               artist: artist, budget: session.budget,
                                                               sleep: env.sleep, onWarming: onWarming),
                         kind: .album, shuffle: shuffle)
    case .song(let title):
        guard args.isEmpty else { throw ActionError(message: bridgePlayExtraWordsRefusal(flag: "song")) }
        try refuseBlank(title, "Song")
        return NamedPlay(selection: try resolveBridgeSongRows(provider: session.provider, title: title,
                                                              artist: artist, budget: session.budget,
                                                              sleep: env.sleep, onWarming: onWarming),
                         kind: .song, shuffle: false)
    case .artist(let name):
        // Loose words were refused above, in the shipped words.
        try refuseBlank(name, "Artist")
        return NamedPlay(selection: try resolveBridgeArtistRows(provider: session.provider, name: name,
                                                                budget: session.budget, sleep: env.sleep,
                                                                onWarming: onWarming),
                         kind: .artist, shuffle: false)
    case .index, .resume, .catalogLink, .words:
        // Callers route these forms elsewhere; refuse rather than guess.
        throw ActionError(message: pickASpanDACOutput)
    }
}

// MARK: - The MusicTUI output with SpanDAC data (score: data route and output, step 6)

/// Where a `music play` invocation's row came from on the DATA axis, for the
/// coordinator's choose-and-play rule (C-MATRIX column 4). Only column 4 needs
/// one: every other column returns nil, and its bodies keep deciding by the
/// cached row exactly as they ship. The ROW's origin decides, never the
/// spelling of its id: a cached row read under MusicTUI's own data is
/// `.openData`, which the coordinator refuses with the CLI's "from before the
/// switch" sentence.
func cliPlayOrigin(_ form: PlayForm, env: CLIBridgeEnv) throws -> PlayOrigin? {
    guard case .consistent(.spandacMac, .musicApp) = env.routing.selection else { return nil }
    switch form {
    case .playlist, .album, .song, .artist:
        return .spandacLibrary
    case .catalogLink:
        return .spandacCatalogue
    case .index(let index):
        let row = try ResultCache.row(index: index, in: env.cache.readSongs())
        switch row.origin {
        case .bridgeLibrary:     return .spandacLibrary
        case .bridgeCatalog:     return .spandacCatalogue
        case .catalog, .library: return .openData(resultNumber: index)
        }
    case .words, .resume:
        return nil
    }
}

/// CHOSEN wording: SpanDAC on this Mac cannot serve MusicTUI's music data
/// right now. Unlike `cliBridgeNotReadySentence` it offers no output switch:
/// the MusicTUI output is already selected, and the data comes from this Mac.
func cliSpanDACDataNotReadySentence(_ readiness: SourceReadiness) -> String {
    let label = readiness.label
    let closed = label.hasSuffix(".") || label.hasSuffix("!") || label.hasSuffix("?") ? label : label + "."
    return closed + " MusicTUI gets its music data from SpanDAC on this Mac."
}

/// `music play` on the MusicTUI output with SpanDAC data, on the path the
/// coordinator named from the row's origin. Library rows (the named forms,
/// and `play N` of a SpanDAC library row) go to `env.libraryPlay`; a catalogue
/// song (`play N` of a SpanDAC catalogue row, or an Apple Music song link)
/// goes to `env.cataloguePlay`. Both are called inside the output lock. Names
/// are resolved against SpanDAC's library on this Mac BEFORE the lock, and
/// nothing here ever sends a request to a SpanDAC output: the MusicTUI output
/// is what plays.
func musicTUIPlayCommand(_ path: MusicTUIPlayPath, args: [String], playlist: String?, album: String?,
                         song: String?, artist: String?, json: Bool, env: CLIBridgeEnv) throws {
    let form = PlayForm(args: args, playlist: playlist, album: album, song: song, artist: artist)
    try refuseNamedFormMisuse(args: args, playlist: playlist, album: album, song: song, artist: artist)
    switch (path, form) {
    case (.handoff, .playlist), (.handoff, .album), (.handoff, .song), (.handoff, .artist):
        let client = env.routing.dataClient()
        let readiness = cliDataReadiness(client)
        guard readiness == .ready else {
            throw ActionError(message: cliSpanDACDataNotReadySentence(readiness))
        }
        let session = CLIBridgeSession(client: client, env: env)
        let named = try resolveNamedPlay(session, args: args, playlist: playlist, album: album, song: song,
                                         artist: artist, env: env)
        switch named.selection {
        case .refused(let why):
            throw ActionError(message: why)
        case .rows(let label, let rows, _, _):
            let request = CLIMusicTUILibraryPlayRequest(kind: named.kind, label: label, rows: rows, startAt: 1,
                                                        shuffle: named.shuffle, resultNumber: nil, json: json)
            try cliMusicTUIMutation(env: env) { try env.libraryPlay.play(request, env: env) }
        }

    case (.handoff, .index(let index)), (.add, .index(let index)):
        let row = try ResultCache.row(index: index, in: env.cache.readSongs())
        switch (path, bridgeRef(forCachedRow: row, index: index)) {
        case (_, .refuse(let why)):
            throw ActionError(message: why)
        case (.handoff, .queue(.libraryQueue(let ids, _))) where ids.count == 1:
            let musicRow = MusicRow(id: ids[0], title: row.title, artist: row.artist,
                                    album: row.album.isEmpty ? nil : row.album, kind: .song)
            let request = CLIMusicTUILibraryPlayRequest(kind: .song, label: row.title, rows: [musicRow], startAt: 1,
                                                        shuffle: false, resultNumber: index, json: json)
            try cliMusicTUIMutation(env: env) { try env.libraryPlay.play(request, env: env) }
        case (.add, .queue(.catalogueQueue(let ids))) where ids.count == 1:
            let request = CLIMusicTUICataloguePlayRequest(catalogueID: ids[0], title: row.title, artist: row.artist,
                                                          album: row.album.isEmpty ? nil : row.album,
                                                          resultNumber: index, json: json)
            try cliMusicTUIMutation(env: env) { try env.cataloguePlay.play(request, env: env) }
        default:
            // The row's origin and the path disagree: refuse, never guess.
            throw ActionError(message: pickASpanDACOutput)
        }

    case (.add, .catalogLink):
        guard let id = appleMusicSongID(from: args[0]) else { throw ActionError(message: pickASpanDACOutput) }
        let request = CLIMusicTUICataloguePlayRequest(catalogueID: id, title: nil, artist: nil, album: nil,
                                                      resultNumber: nil, json: json)
        try cliMusicTUIMutation(env: env) { try env.cataloguePlay.play(request, env: env) }

    default:
        throw ActionError(message: pickASpanDACOutput)
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
        case .station:                         sent = 1   // never from a cached row
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
/// link's song id (`appleMusicSongID`, the `?i=` item or the
/// `/song/[<slug>/]<id>` path form, as the Music.app body reads it) is queued
/// as a catalogue id. No read precedes the mutation.
private func bridgePlaySongLink(_ session: CLIBridgeSession, link: String, json: Bool, env: CLIBridgeEnv) throws {
    guard let id = appleMusicSongID(from: link) else {
        // `PlayForm` classified this as a song link; refuse rather than guess.
        throw ActionError(message: cliBridgeNotServedReason(.cliPlayQuery))
    }
    let ref = BridgePlaybackRef.catalogueQueue(ids: [id])
    let skipped = try session.mutate { try sendBridgeRef(ref, to: $0) }
    bridgeShowAfterMutation(
        session, json: json, env: env,
        resultLines: ["Playing Apple Music song \(id) on SpanDAC."],
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
    case .station(let id, let name):
        // `slice.playStation`: a station replaces the queue; nothing is skipped.
        try control.playStation(id: id, named: name)
        return 0
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

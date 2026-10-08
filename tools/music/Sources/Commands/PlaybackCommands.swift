import ArgumentParser
import Foundation

/// `--artist` alongside loose words: refused, with the spellings that work.
///
/// **It used to be ignored.** With positional args present, the play path passes
/// `artist: nil` to every branch, so `music play "Teardrop" --artist "Massive
/// Attack"` played whatever "Teardrop" matched and never mentioned the artist
/// (Codex, 2026-09-22; Anthony ruled refuse the same day). The words can also
/// name speakers, a volume or `shuffle`, and "play this artist in the kitchen"
/// is a feature with its own decisions — so it is named as not supported yet
/// rather than implied to be wrong.
///
/// nil means the invocation is none of that and proceeds. Pure.
func artistWithLooseWordsRefusal(artist: String?, args: [String],
                                 song: String?, album: String?, playlist: String?) -> String? {
    guard artist != nil, !args.isEmpty, song == nil, album == nil, playlist == nil else { return nil }
    return """
        --artist can't be combined with other words. To play one song by an artist:
          music play --song "Title" --artist "Name"
          music play "Title" "Name"
        To play everything by an artist: music play --artist "Name".
        Naming speakers or a volume together with --artist is not supported yet.
        """
}

struct Play: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Play or resume music.")

    @Argument(help: "Playlist name, result index, or 'shuffle'") var args: [String] = []
    @Option(name: .long, help: "Playlist name") var playlist: String?
    @Option(name: .long, help: "Album name") var album: String?
    @Option(name: .long, help: "Song name") var song: String?
    @Option(name: .long, help: "Artist name") var artist: String?
    @Flag(name: .long, help: "Output JSON") var json = false
    @Flag(name: [.customShort("v"), .customLong("verbose")], help: "Show diagnostic output") var verboseFlag = false

    func run() throws {
        try runPlay(args: args, playlist: playlist, album: album, song: song, artist: artist, json: json,
                    verbose: verboseFlag, env: .live(), musicAppDeps: .live)
    }
}

/// What the Music.app body of `music play` reads outside itself for `play N`
/// (slice 3 S7, R2): the cached rows, and the shipped re-resolve of one row by
/// title. Tests inject both; the rest of the body is the production code.
struct PlayMusicAppDeps {
    var readSongs: () throws -> [SongResult]
    /// Called only for a row `musicAppIndexRoute` sends to `.reResolveByTitle`.
    var resolveIndexed: (SongResult, Int) throws -> Void

    /// The shipped re-resolve, moved verbatim: a bounded local play by title
    /// and artist, then the catalogue add-and-play, else the shipped failure.
    static var live: PlayMusicAppDeps {
        PlayMusicAppDeps(
            readSongs: { try ResultCache().readSongs() },
            resolveIndexed: { song, index in
                let backend = AppleScriptBackend()
                if try !playSongBoundedOrReportFailure(backend: backend, title: song.title, artist: song.artist) {
                    if try !addCatalogSongAndPlay(backend: backend, query: "\(song.title) \(song.artist)", title: song.title, artist: song.artist) {
                        print("'\(song.title)' not in library. Run: music add \(index)")
                        throw ExitCode.failure
                    }
                }
            })
    }
}

/// `music play`, dispatched (slice 3 S7, D1). The matrix decides from the form
/// (`playAction`); the Music.app branch is ALWAYS the production
/// `playViaMusicApp` (no closure override, R2), under the output lock; the
/// Bridge branch is `bridgePlayCommand` (CLIBridgePlay.swift).
func runPlay(args: [String], playlist: String?, album: String?, song: String?, artist: String?,
             json: Bool, verbose: Bool = false, env: CLIBridgeEnv, musicAppDeps: PlayMusicAppDeps) throws {
    try cliDispatch(playAction(args: args, playlist: playlist, album: album, song: song, artist: artist),
                    json: json, env: env,
                    origin: {
                        try cliPlayOrigin(PlayForm(args: args, playlist: playlist, album: album, song: song,
                                                   artist: artist), env: env)
                    },
                    musicApp: {
                        try playViaMusicApp(args: args, playlist: playlist, album: album, song: song,
                                            artist: artist, json: json, verbose: verbose, deps: musicAppDeps)
                    },
                    musicTUI: { path in
                        try musicTUIPlayCommand(path, args: args, playlist: playlist, album: album, song: song,
                                                artist: artist, json: json, env: env)
                    },
                    bridge: {
                        try bridgePlayCommand($0, args: args, playlist: playlist, album: album, song: song,
                                              artist: artist, json: json, env: env)
                    })
}

/// The shipped `music play` body, verbatim, except that `play N` reads the
/// cache through `deps.readSongs`, refuses a Bridge row (`musicAppIndexRoute`,
/// S3), and re-resolves any other row through `deps.resolveIndexed`.
func playViaMusicApp(args: [String], playlist: String?, album: String?, song: String?, artist: String?,
                     json: Bool, verbose verboseFlag: Bool, deps: PlayMusicAppDeps) throws {
        Music.verbose = verboseFlag
        Music.isJSON = json
        let backend = AppleScriptBackend()

        // Existing flag-based behavior takes priority
        if let playlist = playlist {
            let escPlaylist = escapeAppleScriptString(playlist)
            _ = try syncRun {
                try await backend.runMusic("""
                    set shuffle enabled to true
                    play playlist "\(escPlaylist)"
                """)
            }
            showNowPlaying(json: json, waitForPlay: true)
            return
        }

        if let album = album {
            // §16.6: reject an empty/whitespace query BEFORE any library read
            // — `album contains ""` matches the entire library.
            if isBlankAlbumQuery(album) {
                print("Album name can't be empty.")
                throw ExitCode.failure
            }
            // Bounded album play: build a temp container and play it with the
            // bounded `play playlist` form, then let a detached one shot watcher
            // remove the container. Fail closed: no fallback to the unbounded
            // `play track N of playlist "Library"` this replaces.
            // nil is a read that did not answer, not an album that isn't
            // there: say so rather than "No albums found".
            guard let rows = fetchLibraryAlbumRows(
                backend: backend,
                whereClause: albumWhereClause(query: album, artist: artist)) else {
                print(libraryReadFailedMessage(album))
                throw ExitCode.failure
            }
            let outcome = playBoundedAlbum(title: album, rows: rows) { script in
                try? backend.runMusicBlocking(script)
            }
            if let message = albumOutcomeMessage(outcome, title: album) {
                print(message)
                throw ExitCode.failure
            }
            showNowPlaying(json: json, waitForPlay: true)
            return
        }

        if let song = song {
            if try playSongBoundedOrReportFailure(backend: backend, title: song, artist: artist) {
                showNowPlaying(json: json, waitForPlay: true)
                return
            }

            let query = [song, artist].compactMap { $0 }.joined(separator: " ")
            if try addCatalogSongAndPlay(backend: backend, query: query, title: song, artist: artist) {
                showNowPlaying(json: json, waitForPlay: true)
                return
            }

            if let artist {
                print("No local or catalog tracks found matching '\(song)' by '\(artist)'")
            } else {
                print("No local or catalog tracks found matching '\(song)'")
            }
            throw ExitCode.failure
        }

        if let refusal = artistWithLooseWordsRefusal(artist: artist, args: args,
                                                     song: song, album: album, playlist: playlist) {
            print(refusal)
            throw ExitCode.failure
        }

        // `--artist` with nothing else named: ruling 12.2, the artist's SONGS.
        // Before this it fell through to the resume at the end of this method,
        // so the CLI played whatever was already loaded and said nothing.
        if let artist, playlist == nil, album == nil, song == nil, args.isEmpty {
            let resolution = resolveArtistPlaybackTracks(backend: backend, artist: artist)
            guard !resolution.tracks.isEmpty else {
                print(resolution.readFailed ? libraryReadFailedMessage(artist) : resolution.matched > 0
                    ? "Found \(resolution.matched) track(s) by '\(artist)', but none are playable yet (pre-release or removed)."
                    : "No tracks found by '\(artist)'")
                throw ExitCode.failure
            }
            let outcome = playBoundedArtist(name: artist, tracks: resolution.tracks) { script in
                try? backend.runMusicBlocking(script)
            }
            if let message = artistOutcomeMessage(outcome, name: artist) {
                print(message)
                throw ExitCode.failure
            }
            if resolution.matched > resolution.tracks.count {
                print("Playing \(resolution.tracks.count) of \(resolution.matched) — the rest aren't available yet.")
            }
            showNowPlaying(json: json, waitForPlay: true)
            return
        }

        func playSongArtist(title: String, artist: String) throws -> Bool {
            verbose("treating two quoted args as song + artist")
            if try playSongBoundedOrReportFailure(backend: backend, title: title, artist: artist) {
                return true
            }
            return try addCatalogSongAndPlay(
                backend: backend,
                query: "\(title) \(artist)",
                title: title,
                artist: artist
            )
        }

        // Smart positional args
        if !args.isEmpty {
            if args.count == 1,
               let catalogID = appleMusicSongID(from: args[0]) {
                if try addCatalogSongIDAndPlay(backend: backend, id: catalogID) {
                    showNowPlaying(json: json, waitForPlay: true)
                    return
                }
                print("Could not play Apple Music song id \(catalogID)")
                throw ExitCode.failure
            }

            // Single integer → play from cache. A Bridge row is refused before
            // anything reaches AppleScript or REST (S3, D3).
            if args.count == 1, let index = Int(args[0]) {
                let song = try ResultCache.row(index: index, in: deps.readSongs())
                switch musicAppIndexRoute(forCachedRow: song, index: index) {
                case .refuse(let why):
                    printCachedRowRefusal(why, json: json)
                    throw ExitCode.failure
                case .reResolveByTitle:
                    try deps.resolveIndexed(song, index)
                }
                showNowPlaying(json: json, waitForPlay: true)
                return
            }

            // Parse query / speakers / volume / shuffle (see PlayParser).
            // A *failed* enumeration (vs. legitimately no devices) means named
            // speakers in the args won't be recognized and would silently fall
            // into the query — surface that the routing is degraded this run.
            let deviceNames: [String]
            do {
                deviceNames = try fetchSpeakerDevices().compactMap { $0["name"] as? String }
            } catch {
                deviceNames = []
                errorOut("⚠ Couldn't read AirPlay speakers; named-speaker routing is unavailable this run.")
                verbose("fetchSpeakerDevices failed: \(error.localizedDescription)")
            }
            let parsed = PlayParser.parse(args, deviceNames: deviceNames)
            let playlistName = parsed.queryArgs.joined(separator: " ")
            if !parsed.speakers.isEmpty {
                verbose("matched speakers \(parsed.speakers.joined(separator: ", ")) from args")
            }

            // Verify-and-heal support: capture per-speaker network baselines
            // BEFORE routing so establishment shows as churn afterward. A
            // failed resolve degrades to an honest "unverified" note later —
            // never a blocked play.
            var routeBaselines: [String: Set<TCPConnection>] = [:]
            var routeIPs: [String: String] = [:]
            if !parsed.speakers.isEmpty {
                let verifier = RouteVerifier()
                for speaker in parsed.speakers {
                    if let ip = verifier.resolver.resolveIP(forSpeaker: speaker) {
                        routeIPs[speaker] = ip
                        routeBaselines[speaker] = (try? verifier.snapshot(ip: ip)) ?? []
                    }
                }
            }

            // Naming speakers means "play exactly there": select the targets
            // first, then prune the rest (same select-first, per-device-try
            // shape as the speaker command's exclusive mode — a teardown-first
            // order could leave no outputs, and one unreachable device must
            // not abort the rest). Routing and playback stay separate calls.
            if !parsed.speakers.isEmpty {
                for speaker in parsed.speakers {
                    let escSpeaker = escapeAppleScriptString(speaker)
                    _ = try syncRun {
                        try await backend.runMusic("set selected of AirPlay device \"\(escSpeaker)\" to true")
                    }
                }
                let nameList = parsed.speakers
                    .map { "\"\(escapeAppleScriptString($0))\"" }
                    .joined(separator: ", ")
                _ = try syncRun {
                    try await backend.runMusic("""
                        repeat with d in (every AirPlay device)
                            try
                                if selected of d and (name of d is not in {\(nameList)}) then
                                    set selected of d to false
                                end if
                            end try
                        end repeat
                    """)
                }
                if let vol = parsed.volume {
                    for speaker in parsed.speakers {
                        let escSpeaker = escapeAppleScriptString(speaker)
                        _ = try syncRun {
                            try await backend.runMusic("set sound volume of AirPlay device \"\(escSpeaker)\" to \(vol)")
                        }
                    }
                    print(parsed.speakers.map { "\($0) [\(vol)]" }.joined(separator: ", "))
                }
            }

            if parsed.shuffle {
                _ = try syncRun {
                    try await backend.runMusic("set shuffle enabled to true")
                }
            }

            let strategies = PlayResolution.plan(queryArgs: parsed.queryArgs)
            if strategies.isEmpty {
                // Speakers routed (or no args survived parsing) — just resume.
                _ = try syncRun {
                    try await backend.runMusic("play")
                }
            } else {
                var played = false
                for strategy in strategies {
                    switch strategy {
                    case .playlistAlbumSong(let query):
                        // Resolution is separated from playback so only the
                        // album outcome gets the bounded container. Precedence
                        // is unchanged: playlist, then album, then song.
                        let escapedQuery = escapeAppleScriptString(query)
                        // `try?`: a genuine AppleScript failure here degrades to
                        // the generic not-found message rather than surfacing a
                        // distinct error, consistent with the other resolution
                        // helpers in this file.
                        let playlistResult = try? syncRun {
                            try await backend.runMusic("""
                                try
                                    play playlist "\(escapedQuery)"
                                    return "PLAYED"
                                on error
                                    return "NO_PLAYLIST"
                                end try
                            """)
                        }
                        let playlistPlayed = (playlistResult?
                            .trimmingCharacters(in: .whitespacesAndNewlines) == "PLAYED")

                        // §16.6: same empty-query guard as `--album`, applied
                        // defensively here too — belt and braces, since the
                        // positional parser should never hand this an empty
                        // query, but the two album routes must not diverge.
                        // nil is an album read that did not answer; the
                        // route stops on it rather than trying the song branch.
                        let albumRows = (playlistPlayed || isBlankAlbumQuery(query)) ? [] : fetchLibraryAlbumRows(
                            backend: backend,
                            whereClause: albumWhereClause(query: query, artist: nil))

                        switch positionalRoute(playlistPlayed: playlistPlayed,
                                               albumRowCount: albumRows?.count) {
                        case .playlistAlreadyPlaying:
                            played = true
                        case .albumReadFailed:
                            print(libraryReadFailedMessage(query))
                            throw ExitCode.failure
                        case .boundedAlbum:
                            // Starts at the first playable track in disc/track
                            // order (via the shared bounded path), not at
                            // "item 1 of albumMatches" (Library index order)
                            // as the old inline script did. Intentional: this
                            // is what makes positional match `--album`.
                            let outcome = playBoundedAlbum(title: query, rows: albumRows ?? []) { s in
                                try? backend.runMusicBlocking(s)
                            }
                            if let message = albumOutcomeMessage(outcome, title: query) {
                                print(message)
                                throw ExitCode.failure
                            }
                            played = true
                        case .song:
                            // The playability filter (firstPlayablePosition)
                            // still applies, where the old inline script played
                            // "item 1 of songMatches" unconditionally, so a
                            // prerelease or removed track is skipped rather
                            // than silently no-oping. Since 3.12.x the selected
                            // track is played bounded: false here still means
                            // "not in the library", so the catalog fallback
                            // below is reached exactly as before.
                            played = try playSongBoundedOrReportFailure(backend: backend, title: query, artist: nil)
                        }
                    case .songArtist(let title, let artist):
                        played = try playSongArtist(title: title, artist: artist)
                    }
                    if played { break }
                }
                guard played else {
                    print("No playlist, album, or song found matching '\(playlistName)'")
                    throw ExitCode.failure
                }
                if parsed.shuffle {
                    _ = try syncRun {
                        try await backend.runMusic("set shuffle enabled to true")
                    }
                }
            }
            // Routing issued while paused is untrusted (2/2 spike corruptions
            // came from it): verify AFTER playback starts, heal mid-play.
            if !parsed.speakers.isEmpty {
                for line in verifyAndHealRoutes(speakers: parsed.speakers, backend: backend,
                                                baselines: routeBaselines, ips: routeIPs) {
                    // --json consumers parse stdout as one JSON document —
                    // verdict lines go to stderr there (errorOut's channel).
                    if json { errorOut(line) } else { print(line) }
                }
            }
            showNowPlaying(json: json, waitForPlay: true)
            return
        }

        // No args → resume
        _ = try syncRun {
            try await backend.runMusic("play")
        }
        showNowPlaying(json: json, waitForPlay: true)
}

/// Bounded single-song play against the real backend.
///
/// Selection is `playLocalSong`'s, unchanged: the same where clause and the
/// same `firstPlayablePosition`. What changed is that the selected track is
/// played inside its own container and playback stops when it ends, instead of
/// being played at a Library index with the rest of the library behind it.
///
/// The identifier read is a separate one-line script rather than a new column
/// on `LibraryAlbumRow`: adding one would ripple into the shared bulk fetch the
/// album path also uses, and this path needs exactly one id.
func playBoundedSongLive(backend: AppleScriptBackend, title: String, artist: String?) -> SongPlayOutcome {
    playBoundedLocalSong(
        title: title,
        artist: artist,
        fetchRows: { whereClause in
            // nil (the read did not answer) becomes `.libraryReadFailed`.
            fetchLibraryAlbumRows(backend: backend, whereClause: whereClause)
        },
        readIdentifier: { index in
            let raw = try? syncRun {
                try await backend.runMusic(
                    "return persistent ID of track \(index) of playlist \"Library\"")
            }
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        },
        run: { script in try? backend.runMusicBlocking(script) })
}

/// Play a song and report whether the caller may still try the catalog.
///
/// Returns true when playback started. Returns false ONLY when the track is
/// not in the library in playable form, which is what `playLocalSong` used to
/// mean by false. Any other failure prints its own message and throws, because
/// falling through to the catalog after an internal failure would add a copy of
/// a track the user already owns.
func playSongBoundedOrReportFailure(backend: AppleScriptBackend,
                                    title: String,
                                    artist: String?) throws -> Bool {
    let outcome = playBoundedSongLive(backend: backend, title: title, artist: artist)
    if outcome == .playing { return true }
    if outcome.mayFallBackToCatalog { return false }
    if let message = songOutcomeMessage(outcome, title: title) { print(message) }
    throw ExitCode.failure
}

// `playLocalSong` was deleted here in 3.12.x. It selected a song exactly as
// `localSongWhereClause` plus `firstPlayablePosition` still do, and then played
// it with `playQueueTrack(playlist: "Library", position:)`, which left the rest
// of the library queued behind a single requested song. Every entry now routes
// through `playBoundedSongLive`, and the function is gone rather than merely
// unused so the COMPILER is the gate: nothing can call the library-rooted form
// back into existence by accident. The same technique retired
// `playDiscoverContainer` and `sweepDiscoverPlaylists` earlier the same day.
//
// Fetching rows and picking in Swift is still deliberate, and the reason is
// still worth knowing: `play` silently no-ops on pre-release or removed tracks,
// so "item 1 of results" could do nothing while the CLI reported the
// still-playing old track as success.

/// The CLI `play --album` outcome, decided in Swift over fetched rows so the
/// disc-aware order and the playability filter (both live in
/// `orderedPlayableAlbumTracks`, the TUI's resolver exit) apply to the CLI too.
enum AlbumPlayDecision: Equatable {
    /// §17.1: `rows` is the CHOSEN album's own rows (unsorted, unfiltered) —
    /// the one thing that must reach the container. `position`/`playable`/
    /// `matched` describe that same chosen album; they are informational
    /// (the CLI's own message text) and are never used to reconstruct which
    /// rows to seed — `playBoundedAlbum` seeds from `rows` directly.
    ///
    /// §18.5: `displayName` is the chosen `AlbumGroup`'s resolved title
    /// (e.g. "Moon Safari"), distinct from the raw user query (e.g. "moon")
    /// that resolved to it — `playBoundedAlbum` uses it to name the
    /// container so Music's sidebar and Now Playing show the album, not
    /// whatever fragment the user typed.
    case play(rows: [LibraryAlbumRow], displayName: String, position: Int, playable: Int, matched: Int)
    case notFound
    case nonePlayable(matched: Int)
    /// §16.6: the query matched more than one distinct album, and none of
    /// them is a unique exact normalised match, so nothing plays rather than
    /// guessing — and a container is never seeded from more than one album.
    case ambiguous(albums: [String])
}

/// §16.6: `rows` may span more than one album — `whereClause` is a bare
/// `album contains "<query>"`, which is not scoped to one album. Group first
/// (`groupRowsByAlbum`), then decide which single group to play: a unique
/// exact normalised match to `query` wins outright; failing that, the query
/// is accepted only when it resolves to exactly one distinct album; anything
/// else is `.ambiguous` rather than a container spanning several albums.
func decideAlbumPlay(_ rows: [LibraryAlbumRow], query: String) -> AlbumPlayDecision {
    guard !rows.isEmpty else { return .notFound }
    let groups = groupRowsByAlbum(rows)
    let normalizedQuery = normalizeAlbumTitle(query)
    let exact = groups.filter { normalizeAlbumTitle($0.displayName) == normalizedQuery }
    let chosenGroup: AlbumGroup
    if exact.count == 1 {
        chosenGroup = exact[0]
    } else if groups.count == 1 {
        chosenGroup = groups[0]
    } else {
        return .ambiguous(albums: groups.map { $0.displayName })
    }
    let chosen = chosenGroup.rows
    let res = orderedPlayableAlbumTracks(chosen)
    guard let first = res.tracks.first else { return .nonePlayable(matched: res.matched) }
    return .play(rows: chosen, displayName: chosenGroup.displayName, position: first.index,
                playable: res.tracks.count, matched: res.matched)
}

/// First track (source-playlist position) that Music can actually play, in
/// fetch order — song matches span albums, so album order would be meaningless.
func firstPlayablePosition(_ rows: [LibraryAlbumRow]) -> Int? {
    rows.first(where: { isPlayableCloudStatus($0.cloudStatus) })?.index
}

/// Read the identity of every library row whose name contains `title`.
///
/// Scoped to the title rather than the whole library because this is called in
/// a poll loop: a full four-property read of 14k rows costs about 1.5s, while a
/// `whose name contains` query is a fraction of that, and the row we are
/// looking for matches the title by construction.
func libraryRowsMatchingTitle(backend: AppleScriptBackend, title: String) -> [LibraryRowIdentity]? {
    libraryRowsMatchingTitle(run: { script in try? backend.runMusicBlocking(script) }, title: title)
}

/// The same read through any script runner, so a caller that must never reach
/// Apple's Music app in a test (the SpanDAC add path) can hand in a fake.
func libraryRowsMatchingTitle(run: ScriptRunner, title: String) -> [LibraryRowIdentity]? {
    let esc = escapeAppleScriptString(title)
    // The row count is emitted alongside the records so an incomplete read is
    // detectable. A per-row `try` that swallowed a property error used to drop
    // that row silently, which would let it reappear later and be classified as
    // newly added. Completeness is now proven rather than assumed; anything
    // short of it is `nil`, meaning unknown.
    let script = """
    set fs to (ASCII character 31)
    set rs to (ASCII character 30)
    set matches to (every track of playlist "Library" whose name contains "\(esc)")
    set out to ((count of matches) as text) & rs
    repeat with t in matches
        try
            set out to out & (persistent ID of t) & fs & (name of t) & fs & (artist of t) & fs & (album of t) & fs & (cloud status of t as text) & rs
        end try
    end repeat
    return out
    """
    guard let raw = run(script) else { return nil }
    var records = raw.split(separator: "\u{1E}", omittingEmptySubsequences: true).map(String.init)
    guard !records.isEmpty, let expected = Int(records.removeFirst().trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    let rows: [LibraryRowIdentity] = records.compactMap { record in
        let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5 else { return nil }
        return LibraryRowIdentity(persistentID: f[0], name: f[1], artist: f[2], album: f[3],
                                  cloudStatus: f[4])
    }
    // A row the script could not describe is a row we cannot reason about.
    guard rows.count == expected else {
        verbose("library read for \"\(title)\": \(rows.count) of \(expected) rows readable; treating as unknown")
        return nil
    }
    return rows
}

/// Add a catalog song, find the row it created, and play exactly that row.
///
/// Replaces a fixed four-second sleep followed by a name lookup. The sleep was
/// measured at one second of margin on 2026-09-03 (the row appeared at t+3),
/// and a name lookup after an add cannot tell a new row from a copy the user
/// already owned. This snapshots the matching rows BEFORE the add, so the row
/// that appears is identified by set difference and then narrowed by artist and
/// album, and refuses rather than guessing when two new rows remain plausible.
func addCatalogRowAndPlayBounded(backend: AppleScriptBackend,
                                 title: String,
                                 artist: String,
                                 album: String,
                                 addToLibrary: () throws -> Void) throws -> Bool {
    // Refuse BEFORE the irreversible add. A baseline we could not read is not
    // an empty baseline, and adding on top of one would let a pre-existing row
    // be classified as the one the add created.
    guard let baseline = libraryRowsMatchingTitle(backend: backend, title: title) else {
        print("Could not read your library, so '\(title)' was not added and nothing was played.")
        throw ExitCode.failure
    }
    let before = Set(baseline.map { $0.persistentID })
    try addToLibrary()

    let resolution = withStatus("Syncing library...") {
        resolveAddedCatalogRow(
            title: title, artist: artist, album: album, idsBefore: before,
            readRows: { libraryRowsMatchingTitle(backend: backend, title: title) },
            wait: { seconds in
                try? syncRun { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            })
    }

    let result = playResolvedCatalogRow(
        resolution, title: title, note: { print($0) },
        run: { script in try? backend.runMusicBlocking(script) },
        launch: detachedLaunch)
    if result == .playing { return true }
    if case .refused(let message?) = result { print(message) }
    throw ExitCode.failure
}

/// What an add-then-play came to, for a caller that must not print (the TUI)
/// as much as for one that does. `refused` carries the shipped sentence, or
/// nil where the shipped path printed nothing.
enum CatalogAddPlayResult: Equatable {
    case playing
    case refused(String?)
}

/// The tail of `addCatalogRowAndPlayBounded`, shared by the REST and the
/// SpanDAC adds: play exactly the resolved row, or say why not. Nothing here
/// decides anything new; it is the shipped tail with its printing handed in.
func playResolvedCatalogRow(_ resolution: CatalogRowResolution, title: String,
                            note: (String) -> Void, run: ScriptRunner,
                            launch: @escaping ProcessLauncher) -> CatalogAddPlayResult {
    guard case .resolved(let identifier, let viaPreExisting) = resolution else {
        return .refused(catalogRowResolutionMessage(resolution, title: title))
    }
    // Say what kind of match this was. Choosing a row the user already owned is
    // metadata resolution, not catalog identity, and the difference is theirs
    // to know rather than ours to smooth over.
    if viaPreExisting { note(preExistingResolutionNote(title: title)) }

    let outcome = playBoundedSongByIdentifier(title: title, identifier: identifier, run: run, launch: launch)
    if outcome == .playing { return .playing }
    return .refused(songOutcomeMessage(outcome, title: title))
}

// MARK: - Adding through SpanDAC on this Mac (score: data route and output, C-ADD)

/// A catalogue song the MusicTUI output is asked to play with SpanDAC as
/// MusicTUI's data source. `title` is nil for an Apple Music song link, which
/// names only the id.
struct SpanDACCatalogueSong: Equatable {
    let catalogueID: String
    let title: String?
    let artist: String?
    let album: String?
}

/// What one SpanDAC add-then-play came to. Nothing is printed by the player;
/// the TUI and the CLI each say it their own way.
enum SpanDACCataloguePlayOutcome: Equatable {
    /// Playing exactly that song. `note` is the shipped pre-existing-match
    /// note, when the row was chosen by metadata.
    case playing(title: String, note: String?)
    /// Nothing played, for the reason given.
    case refused(String)
    /// The add was sent and its outcome is unknown. Nothing played, nothing is
    /// retried by itself; the next request for this song reconciles first.
    case outcomeUnknown(title: String)
}

/// AppleScript and time, for the add-then-play path. The live value reaches
/// Apple's Music app; tests hand in fakes.
struct CatalogAddPlaySeams {
    var run: ScriptRunner
    var launch: ProcessLauncher
    var wait: (Double) -> Void
    /// The shipped "Syncing library..." status around the resolver (CLI); the
    /// TUI passes it through unchanged, since stderr is its screen.
    var progress: (() -> CatalogRowResolution) -> CatalogRowResolution = { $0() }

    static func live(backend: AppleScriptBackend, showsProgress: Bool) -> CatalogAddPlaySeams {
        var seams = CatalogAddPlaySeams(
            run: { script in try? backend.runMusicBlocking(script) },
            launch: detachedLaunch,
            wait: { seconds in try? syncRun { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } })
        if showsProgress {
            seams.progress = { (body: () -> CatalogRowResolution) -> CatalogRowResolution in
                withStatus("Syncing library...") { body() }
            }
        }
        return seams
    }
}

/// `addCatalogRowAndPlayBounded` with SpanDAC making the add (Anthony
/// 2026-09-28: not-owned songs keep the existing add-then-play path, SpanDAC
/// on this Mac makes the add, no developer key). The preference order:
///
/// 1. Ask SpanDAC first (`libraryLookup`). A song already owned whose alias
///    verifies (exactly one track, same name) plays by it with NO add.
/// 2. Otherwise read the baseline BEFORE the add (unreadable: refuse before
///    adding), add through SpanDAC, then poll the lookup inside the resolver's
///    own wait budget: an alias that appears and verifies plays.
/// 3. Otherwise the shipped set-difference result decides, with its ambiguity
///    and not-found refusals exactly as shipped.
///
/// Only a CONFIRMED failed add refuses outright. An add whose outcome is
/// unknown is remembered with the baseline taken before it: nothing retries by
/// itself, and the next request for the same song (a person's retry) looks it
/// up first, plays it if the add landed, and otherwise adds again against that
/// SAME baseline, never a new one (a re-add is harmless: adding an owned song
/// changes nothing). No developer key or user token is read on this path.
final class SpanDACCataloguePlayer {
    let seams: CatalogAddPlaySeams
    /// The resolver's schedule, as shipped: 20 attempts at 0.5 s.
    static let attempts = 20
    static let interval = 0.5

    /// Catalogue id → the baseline taken before its FIRST add, for an add whose
    /// outcome is unknown. `nil` baseline: a song link, which has no title to
    /// read one by.
    private let lock = NSLock()
    private var unknown: [String: Set<String>?] = [:]

    init(seams: CatalogAddPlaySeams) { self.seams = seams }

    /// Whether an add for this song is waiting to be reconciled. For tests.
    func isAwaitingReconciliation(_ catalogueID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return unknown[catalogueID] != nil
    }

    func play(_ song: SpanDACCatalogueSong, library: SpanDACLibraryAdding) -> SpanDACCataloguePlayOutcome {
        let id = song.catalogueID
        let label = song.title ?? "that song"
        guard library.canAdd else { return .refused(updateSpanDACToPlayOnMusicTUI) }

        // (1) Already owned, by identity. After an add whose outcome was
        // unknown, this is the reconciliation: the add landed, so nothing is
        // added again and nothing is left to reconcile.
        switch verifiedAlias(song, library: library) {
        case .failure(let why): return .refused(why.sentence)
        case .success(let found?):
            lock.lock(); unknown[id] = nil; lock.unlock()
            return playByIdentity(found, song: song)
        case .success(nil): break
        }

        // The baseline: the one taken before the FIRST add, if there was one.
        lock.lock(); let earlier = unknown[id]; lock.unlock()
        let baseline: Set<String>?
        if let earlier {
            baseline = earlier
        } else if let title = song.title {
            guard let rows = libraryRowsMatchingTitle(run: seams.run, title: title) else {
                return .refused("Could not read your library, so '\(title)' was not added and nothing was played.")
            }
            baseline = Set(rows.map { $0.persistentID })
        } else {
            baseline = nil
        }

        // (2) The add. Never retried here.
        do {
            try library.add(catalogueIDs: [id])
        } catch SpanDACLibraryOpError.outcomeUnknown {
            lock.lock(); unknown[id] = .some(baseline); lock.unlock()
            return .outcomeUnknown(title: label)
        } catch {
            lock.lock(); unknown[id] = nil; lock.unlock()
            if case SpanDACLibraryOpError.notOffered = error { return .refused(updateSpanDACToPlayOnMusicTUI) }
            return .refused("SpanDAC couldn't add '\(label)' to your library, so nothing was played. "
                            + (error.localizedDescription))
        }
        lock.lock(); unknown[id] = nil; lock.unlock()

        // (3) Resolve: an alias that appears and verifies wins; the shipped
        // set difference decides otherwise. The lookup runs at each of the
        // resolver's own reads, inside its own wait budget. Once an alias has
        // verified, the resolver's remaining reads return at once and its
        // result is not used.
        var byAlias: (hex: String, name: String)?
        func pollAlias() {
            guard byAlias == nil, case .success(let found?) = verifiedAlias(song, library: library) else { return }
            byAlias = found
        }
        guard let title = song.title, let baseline else {
            // A song link: no title to read a baseline by, so only its
            // identity can say which track the add made.
            for attempt in 1...Self.attempts {
                pollAlias()
                if let found = byAlias { return playByIdentity(found, song: song) }
                if attempt < Self.attempts { seams.wait(Self.interval) }
            }
            return .refused("Added \(label) to your library, but it had not appeared there after "
                            + "\(Self.attempts) checks, so nothing was played. It should be there shortly; "
                            + "try playing it again.")
        }
        let resolution = seams.progress {
            resolveAddedCatalogRow(
                title: title, artist: song.artist ?? "", album: song.album ?? "", idsBefore: baseline,
                attempts: Self.attempts,
                readRows: {
                    pollAlias()
                    return byAlias == nil ? libraryRowsMatchingTitle(run: seams.run, title: title) : nil
                },
                wait: { seconds in if byAlias == nil { seams.wait(seconds) } },
                interval: Self.interval)
        }
        if let found = byAlias { return playByIdentity(found, song: song) }

        var note: String?
        switch playResolvedCatalogRow(resolution, title: title, note: { note = $0 },
                                      run: seams.run, launch: seams.launch) {
        case .playing: return .playing(title: title, note: note)
        case .refused(let why): return .refused(why ?? "Could not play '\(title)'.")
        }
    }

    /// The lookup, verified. `success(nil)`: not owned, or an alias that does
    /// not verify (which the add path then handles as shipped).
    private func verifiedAlias(_ song: SpanDACCatalogueSong,
                               library: SpanDACLibraryAdding) -> Result<(hex: String, name: String)?, LookupFailed> {
        let found: [String: String?]
        do {
            found = try library.lookup(catalogueIDs: [song.catalogueID])
        } catch SpanDACLibraryOpError.notOffered {
            return .failure(LookupFailed(updateSpanDACToPlayOnMusicTUI))
        } catch {
            return .failure(LookupFailed("SpanDAC couldn't check your library, so nothing was played. "
                                         + error.localizedDescription))
        }
        guard case .some(.some(let alias)) = found[song.catalogueID] else { return .success(nil) }
        return .success(verifySpanDACAlias(alias, title: song.title, run: seams.run))
    }

    private func playByIdentity(_ found: (hex: String, name: String),
                                song: SpanDACCatalogueSong) -> SpanDACCataloguePlayOutcome {
        let title = song.title ?? found.name
        let outcome = playBoundedSongByIdentifier(title: title, identifier: found.hex,
                                                  run: seams.run, launch: seams.launch)
        if outcome == .playing { return .playing(title: title, note: nil) }
        return .refused(songOutcomeMessage(outcome, title: title) ?? "Could not play '\(title)'.")
    }

    struct LookupFailed: Error {
        let sentence: String
        init(_ sentence: String) { self.sentence = sentence }
    }
}

func addCatalogSongAndPlay(
    backend: AppleScriptBackend,
    query: String,
    title: String,
    artist: String?
) throws -> Bool {
    let auth = AuthManager()
    let devToken: String
    let userToken: String
    do {
        devToken = try auth.requireDeveloperToken()
        userToken = try auth.requireUserToken()
    } catch AuthError.configNotFound, AuthError.userTokenRequired {
        // Genuinely not set up — the catalog path simply doesn't apply.
        verbose("catalog fallback unavailable: MusicKit auth is not configured")
        return false
    } catch {
        // Auth IS set up but broken (corrupt config / expired token / key) —
        // surface it so the user isn't told the song doesn't exist.
        errorOut("✗ Apple Music auth error: \(error.localizedDescription)")
        return false
    }

    let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
    let songs = try syncRun { try await api.searchSongs(query: query, limit: 5) }
    guard !songs.isEmpty else { return false }

    let preferredArtist = artist?.lowercased()
    let preferredTitle = title.lowercased()
    let selected = songs.first {
        $0.title.lowercased().contains(preferredTitle)
            && (preferredArtist == nil || $0.artist.lowercased().contains(preferredArtist!))
    } ?? songs.first {
        preferredArtist == nil || $0.artist.lowercased().contains(preferredArtist!)
    } ?? songs[0]

    verbose("catalog fallback matched \"\(selected.title)\" by \"\(selected.artist)\"")
    return try addCatalogRowAndPlayBounded(
        backend: backend, title: selected.title, artist: selected.artist, album: selected.album,
        addToLibrary: { try syncRun { try await api.addToLibrary(songIDs: [selected.id]) } })
}

func addCatalogSongIDAndPlay(backend: AppleScriptBackend, id: String) throws -> Bool {
    let auth = AuthManager()
    let devToken: String
    let userToken: String
    do {
        devToken = try auth.requireDeveloperToken()
        userToken = try auth.requireUserToken()
    } catch AuthError.configNotFound, AuthError.userTokenRequired {
        verbose("catalog URL playback unavailable: MusicKit auth is not configured")
        return false
    } catch {
        errorOut("✗ Apple Music auth error: \(error.localizedDescription)")
        return false
    }

    let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
    let song = try syncRun { try await api.song(id: id) }
    verbose("catalog URL matched \"\(song.title)\" by \"\(song.artist)\"")
    return try addCatalogRowAndPlayBounded(
        backend: backend, title: song.title, artist: song.artist, album: song.album,
        addToLibrary: { try syncRun { try await api.addToLibrary(songIDs: [song.id]) } })
}

/// The song id an Apple Music link names, or nil. Two forms:
/// - `…/album/<slug>/<albumID>?i=<songID>`: the `i` query item (checked first).
/// - `https://music.apple.com/<sf>/song[/<slug>]/<songID>`: `<sf>` is any two
///   letters, the query string is ignored, and empty path segments (doubled
///   slashes) are skipped. The id must be all ASCII digits; anything else is
///   refused rather than guessed. Album, playlist, artist and station paths
///   never match here.
func appleMusicSongID(from value: String) -> String? {
    guard value.contains("music.apple.com"),
          let components = URLComponents(string: value) else {
        return nil
    }
    if let itemID = components.queryItems?.first(where: { $0.name == "i" })?.value,
       !itemID.isEmpty {
        return itemID
    }
    guard components.host == "music.apple.com" else { return nil }
    let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard segments.count == 3 || segments.count == 4,
          segments[0].count == 2,
          segments[0].allSatisfy({ $0.isASCII && $0.isLetter }),
          segments[1] == "song",
          let id = segments.last,
          !id.isEmpty,
          id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        return nil
    }
    return id
}

// MARK: - Transport and now (slice 3 S6: dispatched per D1)
//
// Each verb's `run()` builds one `CLIBridgeEnv.live()` and calls `run<Verb>`,
// whose first statement is `cliDispatch`: the matrix picks exactly one branch.
// The `<verb>ViaMusicApp` functions are the shipped bodies, moved verbatim;
// the Bridge bodies are in CLIBridgeTransport.swift.

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause playback.")
    func run() throws {
        try runPause(env: .live())
    }
}

func runPause(env: CLIBridgeEnv, musicApp: () throws -> Void = pauseViaMusicApp) throws {
    try cliDispatch(.playPause, json: false, env: env, musicApp: musicApp,
                    bridge: { try bridgePauseCommand($0, env: env) })
}

func pauseViaMusicApp() throws {
    let backend = AppleScriptBackend()
    _ = try backend.runMusicBlocking("pause")
    print("Paused.")
}

struct Skip: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Skip to next track.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        try runSkip(json: json, env: .live())
    }
}

func runSkip(json: Bool, env: CLIBridgeEnv, musicApp: (Bool) throws -> Void = skipViaMusicApp) throws {
    try cliDispatch(.next, json: json, env: env, musicApp: { try musicApp(json) },
                    bridge: { try bridgeStepCommand($0, json: json, env: env) { try $0.next() } })
}

func skipViaMusicApp(json: Bool) throws {
    let backend = AppleScriptBackend()
    _ = try backend.runMusicBlocking("next track")
    showNowPlaying(json: json, waitForPlay: true)
}

struct Back: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Go to previous track.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        try runBack(json: json, env: .live())
    }
}

func runBack(json: Bool, env: CLIBridgeEnv, musicApp: (Bool) throws -> Void = backViaMusicApp) throws {
    try cliDispatch(.previous, json: json, env: env, musicApp: { try musicApp(json) },
                    bridge: { try bridgeStepCommand($0, json: json, env: env) { try $0.previous() } })
}

func backViaMusicApp(json: Bool) throws {
    let backend = AppleScriptBackend()
    _ = try backend.runMusicBlocking("previous track")
    showNowPlaying(json: json, waitForPlay: true)
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop playback.")
    func run() throws {
        try runStop(env: .live())
    }
}

func runStop(env: CLIBridgeEnv, musicApp: () throws -> Void = stopViaMusicApp) throws {
    try cliDispatch(.stop, json: false, env: env, musicApp: musicApp,
                    bridge: { try bridgeStopCommand($0, env: env) })
}

func stopViaMusicApp() throws {
    let backend = AppleScriptBackend()
    _ = try backend.runMusicBlocking("stop")
    print("Stopped.")
}

struct Now: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what's currently playing.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let bareMusic = CommandLine.arguments.dropFirst().isEmpty   // `music` with no subcommand
        let bareNow = isBareInvocation(command: "now")              // `music now` with no flags
        if (bareMusic || bareNow) && isTTY() {
            runShell()
            return
        }
        try runNow(json: json, env: .live())
    }
}

func runNow(json: Bool, env: CLIBridgeEnv, musicApp: (Bool) throws -> Void = nowViaMusicApp) throws {
    try cliDispatch(.nowStatus, json: json, env: env, musicApp: { try musicApp(json) },
                    bridge: { try bridgeNowCommand($0, json: json, env: env) })
}

func nowViaMusicApp(json: Bool) throws {
    showNowPlaying(json: json)
}

/// The one player state that means a play has actually landed.
///
/// Single-sourced deliberately: the guard that runs is AppleScript, so
/// `nowPlayingShouldWait` below cannot be the live code path, and a second
/// copy of this string in the generated script is exactly how the two would
/// drift. `testGeneratedGuardKeysOnTheSameReadyStateAsThePredicate` pins them
/// together.
let nowPlayingReadyState = "playing"

/// Whether a `now` read should retry instead of reporting what it just saw.
///
/// Only when we are waiting for a play we just issued. The old guard waited
/// out `stopped` alone, which left a real window open: measured 2026-08-30
/// across four runs, a play issued from PAUSED reads back as
/// `paused | <old track>` before it becomes `stopped | <new track>` and then
/// `playing | <new track>`. So the outgoing track was printed as though the
/// new one had started. Anything that is not `playing` is still in flight.
///
/// Deliberately NOT keyed on the track identity: `playing` never appeared next
/// to a stale track in any run, and an identity check would spin for the full
/// timeout on `music play` with no arguments, where resuming keeps the same
/// track by definition.
func nowPlayingShouldWait(state: String, waitForPlay: Bool) -> Bool {
    guard waitForPlay else { return false }
    return state != nowPlayingReadyState
}

/// The state guard emitted into the read loop.
///
/// Waiting form: throw back into the surrounding `repeat`, which retries on its
/// existing bound (10 attempts, 0.3s apart) and falls through to "LOADING" if
/// playback never lands. Non-waiting form is unchanged, and must NOT error, or
/// `music now` would retry ten times on a stopped player instead of saying so.
func nowPlayingStateGuard(waitForPlay: Bool) -> String {
    waitForPlay ? """
                    if state is not "\(nowPlayingReadyState)" then
                        error "waiting for playback"
                    end if
    """ : """
                    if state is "stopped" then
                        return "STOPPED"
                    end if
    """
}

func showNowPlaying(json: Bool = false, waitForPlay: Bool = false) {
    let backend = AppleScriptBackend()
    let stateGuard = nowPlayingStateGuard(waitForPlay: waitForPlay)
    // Device enumeration happens ONCE after the track info succeeds — it used
    // to run inside every iteration of the retry loop, multiplying the
    // known-slow AirPlay probe by up to 10 after every playback command. The
    // bulk `whose selected is true` reads are 2 Apple Events instead of 3 per
    // device (the per-list repeat below is local, no Apple Events).
    let result: String
    do {
        result = try syncRun({
        try await backend.runMusic("""
            set fs to (ASCII character 31)
            set info to ""
            repeat 10 times
                try
                    set state to player state as text
                    \(stateGuard)
                    set t to name of current track
                    set a to artist of current track
                    set al to album of current track
                    set d to duration of current track
                    set p to player position
                    set lv to "0"
                    if (class of current track is URL track) and (d is missing value) then set lv to "1"
                    if d is missing value then
                        set dTxt to "-"
                    else
                        set dTxt to ((round d) as text)
                    end if
                    if p is missing value then
                        set pTxt to "-"
                    else
                        set pTxt to ((round p) as text)
                    end if
                    if a is missing value then set a to ""
                    if al is missing value then set al to ""
                    set info to t & fs & a & fs & al & fs & dTxt & fs & pTxt & fs & state & fs & lv
                    exit repeat
                end try
                delay 0.3
            end repeat
            if info is "" then return "LOADING"
            set spk to ""
            try
                set selNames to name of (every AirPlay device whose selected is true)
                set selVols to sound volume of (every AirPlay device whose selected is true)
                repeat with i from 1 to (count of selNames)
                    if spk is not "" then set spk to spk & ","
                    set spk to spk & (item i of selNames) & ":" & (item i of selVols)
                end repeat
            end try
            return info & fs & spk
        """)
        })
    } catch {
        if json {
            print(#"{"error": "could not read now playing"}"#)
        } else {
            errorOut("✗ Couldn't read now playing: \(error.localizedDescription)")
        }
        return
    }

    switch parseNowOutput(result) {
    case .stopped:
        print(json ? "{\"state\":\"stopped\"}" : "Nothing playing.")
    case .loading, .none:
        if json {
            print(#"{"error": "could not read now playing"}"#)
        } else {
            errorOut("✗ Couldn't read now playing.")
        }
    case .info(let i):
        let speakers = i.speakers.map { ["name": $0.name, "volume": $0.volume] as [String: Any] }
        if json {
            var dict: [String: Any] = ["track": i.track, "artist": i.artist, "album": i.album,
                                       "state": i.state, "speakers": speakers]
            if i.isLive {
                dict["live"] = true          // duration/position deliberately ABSENT
            } else {
                dict["duration"] = i.duration ?? 0
                dict["position"] = i.position ?? 0
            }
            print(OutputFormat(mode: .json).render(dict))
        } else {
            let spkStr = i.speakers.map { "\($0.name) (vol: \($0.volume))" }.joined(separator: " | ")
            if i.isLive {
                let who = i.artist.isEmpty ? i.track : "\(i.track) — \(i.artist)"
                print("\(who) [LIVE]")
            } else {
                print("\(i.track) — \(i.artist) [\(i.album)]")
            }
            if !spkStr.isEmpty { print(spkStr) }
        }
    }
}

/// Parse a seek target: "+30"/"-30" = relative seconds, "90" = absolute
/// seconds, "1:30" = absolute m:ss. nil on garbage. Pure.
func parseSeekTarget(_ value: String) -> (delta: Int?, absolute: Int?)? {
    let v = value.trimmingCharacters(in: .whitespaces)
    if v.hasPrefix("+") || v.hasPrefix("-") {
        guard let d = Int(v) else { return nil }
        return (delta: d, absolute: nil)
    }
    if v.contains(":") {
        let parts = v.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]), m >= 0, (0..<60).contains(s) else { return nil }
        return (delta: nil, absolute: m * 60 + s)
    }
    guard let abs = Int(v), abs >= 0 else { return nil }
    return (delta: nil, absolute: abs)
}

struct Seek: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Seek within the current track.")
    @Argument(help: "+30 / -30 (relative seconds), 90 (seconds), or 1:30") var position: String
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        try runSeek(position: position, json: json, env: .live())
    }
}

/// Each branch parses the position itself: the Music.app body as it ships
/// (a `ValidationError`), the Bridge body in D5's failure form.
func runSeek(position: String, json: Bool, env: CLIBridgeEnv,
             musicApp: (String, Bool) throws -> Void = seekViaMusicApp) throws {
    try cliDispatch(.seek, json: json, env: env, musicApp: { try musicApp(position, json) },
                    bridge: { try bridgeSeekCommand($0, position: position, json: json, env: env) })
}

func seekViaMusicApp(position: String, json: Bool) throws {
    guard let target = parseSeekTarget(position) else {
        throw ValidationError("Position must be +N / -N, seconds, or m:ss (e.g. +30, 90, 1:30).")
    }
    let backend = AppleScriptBackend()
    let script = target.delta.map { "set player position to (player position + \($0))" }
        ?? "set player position to \(target.absolute!)"
    let result = try syncRun {
        try await backend.runMusic("""
            if player state is stopped then return "NOTHING"
            \(script)
            delay 0.2
            set p to player position
            return (round p) as text
        """)
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "NOTHING" {
        print(json ? "{\"ok\":false,\"error\":\"nothing playing\"}" : "Nothing playing.")
        throw ExitCode.failure
    }
    let pos = Int(trimmed) ?? 0
    print(json ? "{\"ok\":true,\"position\":\(pos)}" : "Position \(formatTime(pos)).")
}

// Shuffle and repeat MODES are validated before dispatch, so a bad word reaches
// neither output. With SpanDAC selected they send `slice.shuffle` /
// `slice.repeat` (`bridgeShuffleCommand`, `bridgeRepeatCommand`); in Music.app
// mode their shipped bodies run inside the output lock.

/// `music shuffle`'s word: nil toggles, "on"/"off" (any case) set it. Anything
/// else is the shipped ValidationError. (`music shuffle banana` used to print
/// "Shuffle banana." and set it OFF.)
func parseShuffleWord(_ state: String?) throws -> Bool? {
    guard let state else { return nil }
    switch state.lowercased() {
    case "on":  return true
    case "off": return false
    default: throw ValidationError("Shuffle must be on or off (or omitted to toggle).")
    }
}

/// `music repeat`'s word: off, one or all (any case); anything else is the
/// shipped ValidationError.
func parseRepeatWord(_ mode: String) throws -> RepeatMode {
    guard let parsed = RepeatMode(rawValue: mode.lowercased()) else {
        throw ValidationError("Repeat mode must be off, one, or all.")
    }
    return parsed
}

struct Shuffle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Toggle shuffle (or set on/off).")
    @Argument(help: "on or off (omit to toggle)") var state: String?
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        try runShuffle(state: state, json: json, env: .live())
    }
}

func runShuffle(state: String?, json: Bool, env: CLIBridgeEnv,
                musicApp: (String?, Bool) throws -> Void = shuffleViaMusicApp) throws {
    let wanted = try parseShuffleWord(state)
    try cliDispatch(.persistentShuffleMode, json: json, env: env, musicApp: { try musicApp(state, json) },
                    bridge: { try bridgeShuffleCommand($0, on: wanted, json: json, env: env) })
}

func shuffleViaMusicApp(state: String?, json: Bool) throws {
    let backend = AppleScriptBackend()
    let newState: String
    if let on = try parseShuffleWord(state) {
        _ = try backend.runMusicBlocking("set shuffle enabled to \(on)")
        newState = on ? "on" : "off"
    } else {
        let result = try syncRun {
            try await backend.runMusic("""
                if shuffle enabled then
                    set shuffle enabled to false
                    return "off"
                else
                    set shuffle enabled to true
                    return "on"
                end if
            """)
        }
        newState = result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    print(json ? "{\"shuffle\":\"\(newState)\"}" : "Shuffle \(newState).")
}

struct Repeat_: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "repeat", abstract: "Set repeat mode.")
    @Argument(help: "off, one, or all") var mode: String
    func run() throws {
        try runRepeat(mode: mode, env: .live())
    }
}

func runRepeat(mode: String, env: CLIBridgeEnv, musicApp: (String) throws -> Void = repeatViaMusicApp) throws {
    let wanted = try parseRepeatWord(mode)
    try cliDispatch(.persistentRepeatMode, json: false, env: env, musicApp: { try musicApp(mode) },
                    bridge: { try bridgeRepeatCommand($0, mode: wanted, env: env) })
}

func repeatViaMusicApp(mode: String) throws {
    let m = try parseRepeatWord(mode).rawValue
    let backend = AppleScriptBackend()
    _ = try backend.runMusicBlocking("set song repeat to \(m)")
    print("Repeat \(m).")
}

// MARK: - Sync helper for running async from sync ParsableCommand.run()

func syncRun<T>(_ block: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task {
        do {
            result = .success(try await block())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

import ArgumentParser
import Foundation

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
            let rows = fetchLibraryAlbumRows(
                backend: backend,
                whereClause: albumWhereClause(query: album, artist: artist))
            let outcome = playBoundedAlbum(title: album, rows: rows) { script in
                try? syncRun { try await backend.runMusic(script) }
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

            // Single integer → play from cache
            if args.count == 1, let index = Int(args[0]) {
                let cache = ResultCache()
                let song = try cache.lookupSong(index: index)
                if try !playSongBoundedOrReportFailure(backend: backend, title: song.title, artist: song.artist) {
                    if try !addCatalogSongAndPlay(backend: backend, query: "\(song.title) \(song.artist)", title: song.title, artist: song.artist) {
                        print("'\(song.title)' not in library. Run: music add \(index)")
                        throw ExitCode.failure
                    }
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
                        let albumRows = (playlistPlayed || isBlankAlbumQuery(query)) ? [] : fetchLibraryAlbumRows(
                            backend: backend,
                            whereClause: albumWhereClause(query: query, artist: nil))

                        switch positionalRoute(playlistPlayed: playlistPlayed,
                                               albumRowCount: albumRows.count) {
                        case .playlistAlreadyPlaying:
                            played = true
                        case .boundedAlbum:
                            // Starts at the first playable track in disc/track
                            // order (via the shared bounded path), not at
                            // "item 1 of albumMatches" (Library index order)
                            // as the old inline script did. Intentional: this
                            // is what makes positional match `--album`.
                            let outcome = playBoundedAlbum(title: query, rows: albumRows) { s in
                                try? syncRun { try await backend.runMusic(s) }
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
        run: { script in try? syncRun { try await backend.runMusic(script) } })
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
            set out to out & (persistent ID of t) & fs & (name of t) & fs & (artist of t) & fs & (album of t) & rs
        end try
    end repeat
    return out
    """
    guard let raw = try? syncRun({ try await backend.runMusic(script) }) else { return nil }
    var records = raw.split(separator: "\u{1E}", omittingEmptySubsequences: true).map(String.init)
    guard !records.isEmpty, let expected = Int(records.removeFirst().trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    let rows: [LibraryRowIdentity] = records.compactMap { record in
        let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4 else { return nil }
        return LibraryRowIdentity(persistentID: f[0], name: f[1], artist: f[2], album: f[3])
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

    guard case .resolved(let identifier) = resolution else {
        if let message = catalogRowResolutionMessage(resolution, title: title) { print(message) }
        throw ExitCode.failure
    }

    let outcome = playBoundedSongByIdentifier(
        title: title, identifier: identifier,
        run: { script in try? syncRun { try await backend.runMusic(script) } })
    if outcome == .playing { return true }
    if let message = songOutcomeMessage(outcome, title: title) { print(message) }
    throw ExitCode.failure
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

func appleMusicSongID(from value: String) -> String? {
    guard value.contains("music.apple.com"),
          let components = URLComponents(string: value),
          let itemID = components.queryItems?.first(where: { $0.name == "i" })?.value,
          !itemID.isEmpty else {
        return nil
    }
    return itemID
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause playback.")
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun { try await backend.runMusic("pause") }
        print("Paused.")
    }
}

struct Skip: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Skip to next track.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun { try await backend.runMusic("next track") }
        showNowPlaying(json: json, waitForPlay: true)
    }
}

struct Back: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Go to previous track.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun { try await backend.runMusic("previous track") }
        showNowPlaying(json: json, waitForPlay: true)
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop playback.")
    func run() throws {
        let backend = AppleScriptBackend()
        _ = try syncRun { try await backend.runMusic("stop") }
        print("Stopped.")
    }
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
        showNowPlaying(json: json)
    }
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
}

struct Shuffle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Toggle shuffle (or set on/off).")
    @Argument(help: "on or off (omit to toggle)") var state: String?
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let backend = AppleScriptBackend()
        let newState: String
        if let state = state {
            let s = state.lowercased()
            // `music shuffle banana` used to print "Shuffle banana." and set it OFF.
            guard s == "on" || s == "off" else { throw ValidationError("Shuffle must be on or off (or omitted to toggle).") }
            _ = try syncRun { try await backend.runMusic("set shuffle enabled to \(s == "on")") }
            newState = s
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
}

struct Repeat_: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "repeat", abstract: "Set repeat mode.")
    @Argument(help: "off, one, or all") var mode: String
    func run() throws {
        let m = mode.lowercased()
        guard ["off", "one", "all"].contains(m) else {
            throw ValidationError("Repeat mode must be off, one, or all.")
        }
        let backend = AppleScriptBackend()
        _ = try syncRun { try await backend.runMusic("set song repeat to \(m)") }
        print("Repeat \(m).")
    }
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

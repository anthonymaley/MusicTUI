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
            // Remix/compilation albums credit each track to the remixer, so also match album artist.
            let artistFilter = albumArtistFilter(artist: artist)
            let escAlbum = escapeAppleScriptString(album)
            let result = try syncRun {
                try await backend.runMusic("""
                    set results to (every track of playlist "Library" whose album contains "\(escAlbum)"\(artistFilter))
                    if (count of results) > 0 then
                        set firstTrack to item 1 of results
                        set firstNumber to 9999
                        repeat with t in results
                            try
                                set n to track number of t
                                if n > 0 and n < firstNumber then
                                    set firstNumber to n
                                    set firstTrack to t
                                end if
                            end try
                        end repeat
                        play firstTrack
                        return "OK"
                    else
                        return "NOT_FOUND"
                    end if
                """)
            }
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "NOT_FOUND" {
                print("No albums found matching '\(album)'")
                throw ExitCode.failure
            }
            showNowPlaying(json: json, waitForPlay: true)
            return
        }

        if let song = song {
            if try playLocalSong(backend: backend, title: song, artist: artist) {
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
            if try playLocalSong(backend: backend, title: title, artist: artist) {
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
                if try !playLocalSong(backend: backend, title: song.title, artist: song.artist) {
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
                        let escapedQuery = escapeAppleScriptString(query)
                        let result = try syncRun {
                            try await backend.runMusic("""
                                try
                                    play playlist "\(escapedQuery)"
                                    return "PLAYLIST"
                                on error
                                    set albumMatches to (every track of playlist "Library" whose album contains "\(escapedQuery)")
                                    if (count of albumMatches) > 0 then
                                        play item 1 of albumMatches
                                        return "ALBUM"
                                    end if
                                    set songMatches to (every track of playlist "Library" whose name contains "\(escapedQuery)")
                                    if (count of songMatches) > 0 then
                                        play item 1 of songMatches
                                        return "SONG"
                                    end if
                                    return "NOT_FOUND"
                                end try
                            """)
                        }
                        played = result.trimmingCharacters(in: .whitespacesAndNewlines) != "NOT_FOUND"
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

func playLocalSong(backend: AppleScriptBackend, title: String, artist: String?) throws -> Bool {
    let escapedTitle = escapeAppleScriptString(title)
    let artistFilter = artist.map {
        " and artist contains \"\(escapeAppleScriptString($0))\""
    } ?? ""
    let result = try syncRun {
        try await backend.runMusic("""
            set results to (every track of playlist "Library" whose name contains "\(escapedTitle)"\(artistFilter))
            if (count of results) > 0 then
                play item 1 of results
                return "OK"
            else
                return "NOT_FOUND"
            end if
        """)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines) != "NOT_FOUND"
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
    try syncRun { try await api.addToLibrary(songIDs: [selected.id]) }
    withStatus("Syncing library...") {
        try! syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
    }

    return try playLocalSong(backend: backend, title: selected.title, artist: selected.artist)
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
    try syncRun { try await api.addToLibrary(songIDs: [song.id]) }
    withStatus("Syncing library...") {
        try! syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
    }

    return try playLocalSong(backend: backend, title: song.title, artist: song.artist)
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

func showNowPlaying(json: Bool = false, waitForPlay: Bool = false) {
    let backend = AppleScriptBackend()
    let stoppedCheck = waitForPlay ? """
                    if state is "stopped" then
                        error "waiting for playback"
                    end if
    """ : """
                    if state is "stopped" then
                        return "STOPPED"
                    end if
    """
    // Device enumeration happens ONCE after the track info succeeds — it used
    // to run inside every iteration of the retry loop, multiplying the
    // known-slow AirPlay probe by up to 10 after every playback command. The
    // bulk `whose selected is true` reads are 2 Apple Events instead of 3 per
    // device (the per-list repeat below is local, no Apple Events).
    let result: String
    do {
        result = try syncRun({
        try await backend.runMusic("""
            set info to ""
            repeat 10 times
                try
                    set state to player state as text
                    \(stoppedCheck)
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
                    set info to t & "|" & a & "|" & al & "|" & dTxt & "|" & pTxt & "|" & state & "|" & lv
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
            return info & "|" & spk
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

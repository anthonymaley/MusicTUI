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
    @Flag(name: .long, help: "Skip speaker wake cycle") var noWake = false

    func run() throws {
        Music.verbose = verboseFlag
        Music.isJSON = json
        Music.noWake = noWake
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
            let artistFilter = artist.map { " and artist contains \"\(escapeAppleScriptString($0))\"" } ?? ""
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

            // Check for trailing "shuffle" keyword
            let hasShuffle = args.last?.lowercased() == "shuffle"
            var remaining = hasShuffle ? Array(args.dropLast()) : args

            // Extract volume (last arg if it's a number 0-100)
            var speakerVolume: Int? = nil
            if remaining.count >= 2, let vol = Int(remaining.last!), (0...100).contains(vol) {
                speakerVolume = vol
                remaining = Array(remaining.dropLast())
            }

            // Try to match a speaker name from the args (longest match wins)
            var matchedSpeaker: String? = nil
            var playlistName: String
            let joinedLower = remaining.joined(separator: " ").lowercased()

            if let devices = try? fetchSpeakerDevices() {
                let deviceNames = devices.map { $0["name"] as! String }
                var bestLen = 0
                for devName in deviceNames {
                    let devLower = devName.lowercased()
                    if joinedLower.contains(devLower) && devLower.count > bestLen {
                        matchedSpeaker = devName
                        bestLen = devLower.count
                    }
                }
                if let speaker = matchedSpeaker {
                    verbose("matched speaker \"\(speaker)\" from args")
                    // Remove speaker name from the joined string to get playlist name
                    let cleaned = joinedLower.replacingOccurrences(of: speaker.lowercased(), with: "")
                        .trimmingCharacters(in: .whitespaces)
                    playlistName = cleaned.isEmpty ? "" : cleaned
                    // Restore original case from args for the playlist name
                    if !cleaned.isEmpty {
                        // Re-join args without the speaker words
                        let speakerWords = Set(speaker.lowercased().split(separator: " ").map(String.init))
                        let playlistArgs = remaining.filter { !speakerWords.contains($0.lowercased()) }
                        playlistName = playlistArgs.joined(separator: " ")
                    }
                } else {
                    playlistName = remaining.joined(separator: " ")
                }
            } else {
                playlistName = remaining.joined(separator: " ")
            }

            // Route to speaker without forcing a full AirPlay reset.
            if let speaker = matchedSpeaker {
                let escSpeaker = escapeAppleScriptString(speaker)
                _ = try syncRun {
                    try await backend.runMusic("set selected of AirPlay device \"\(escSpeaker)\" to true")
                }
                // Set volume if specified
                if let vol = speakerVolume {
                    _ = try syncRun {
                        try await backend.runMusic("set sound volume of AirPlay device \"\(escSpeaker)\" to \(vol)")
                    }
                    print("\(speaker) [\(vol)]")
                }
            }

            if hasShuffle {
                _ = try syncRun {
                    try await backend.runMusic("set shuffle enabled to true")
                }
            }

            if remaining.count == 2,
               try playSongArtist(title: remaining[0], artist: remaining[1]) {
                if hasShuffle {
                    _ = try syncRun {
                        try await backend.runMusic("set shuffle enabled to true")
                    }
                }
                showNowPlaying(json: json, waitForPlay: true)
                return
            }

            if !playlistName.isEmpty {
                let escapedQuery = playlistName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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
                if result.trimmingCharacters(in: .whitespacesAndNewlines) == "NOT_FOUND" {
                    print("No playlist, album, or song found matching '\(playlistName)'")
                    throw ExitCode.failure
                }
            } else if matchedSpeaker != nil {
                // Speaker routed but no playlist specified — just resume
                _ = try syncRun {
                    try await backend.runMusic("play")
                }
            } else {
                // No speaker, no playlist — shouldn't happen but resume
                _ = try syncRun {
                    try await backend.runMusic("play")
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
    let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let artistFilter = artist.map {
        " and artist contains \"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
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
    guard let devToken = try? auth.requireDeveloperToken(),
          let userToken = try? auth.requireUserToken() else {
        verbose("catalog fallback unavailable: MusicKit auth is not configured")
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
    guard let devToken = try? auth.requireDeveloperToken(),
          let userToken = try? auth.requireUserToken() else {
        verbose("catalog URL playback unavailable: MusicKit auth is not configured")
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
    guard let result = try? syncRun({
        try await backend.runMusic("""
            repeat 10 times
                try
                    set state to player state as text
                    \(stoppedCheck)
                    set t to name of current track
                    set a to artist of current track
                    set al to album of current track
                    set d to duration of current track
                    set p to player position
                    set spk to ""
                    set deviceList to every AirPlay device
                    repeat with dev in deviceList
                        if selected of dev then
                            if spk is not "" then set spk to spk & ","
                            set spk to spk & name of dev & ":" & sound volume of dev
                        end if
                    end repeat
                    return t & "|" & a & "|" & al & "|" & (round d) & "|" & (round p) & "|" & state & "|" & spk
                end try
                delay 0.3
            end repeat
            return "LOADING"
        """)
    }) else { return }

    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "STOPPED" {
        print(json ? "{\"state\":\"stopped\"}" : "Nothing playing.")
        return
    }
    let parts = trimmed.split(separator: "|", maxSplits: 6).map(String.init)
    guard parts.count >= 7 else { print("Unexpected output"); return }

    let speakers = parts[6].split(separator: ",").map { pair -> [String: Any] in
        let kv = pair.split(separator: ":", maxSplits: 1)
        return ["name": String(kv[0]), "volume": Int(kv.count > 1 ? String(kv[1]) : "0") ?? 0]
    }

    if json {
        let dict: [String: Any] = [
            "track": parts[0], "artist": parts[1], "album": parts[2],
            "duration": Int(parts[3]) ?? 0, "position": Int(parts[4]) ?? 0,
            "state": parts[5], "speakers": speakers
        ]
        let output = OutputFormat(mode: .json)
        print(output.render(dict))
    } else {
        let spkStr = speakers.map { "\($0["name"]!) (vol: \($0["volume"]!))" }.joined(separator: " | ")
        print("\(parts[0]) — \(parts[1]) [\(parts[2])]")
        if !spkStr.isEmpty { print(spkStr) }
    }
}

struct Shuffle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Toggle shuffle.")
    @Argument(help: "on or off") var state: String
    func run() throws {
        let backend = AppleScriptBackend()
        let val = state.lowercased() == "on" ? "true" : "false"
        _ = try syncRun { try await backend.runMusic("set shuffle enabled to \(val)") }
        print("Shuffle \(state.lowercased()).")
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

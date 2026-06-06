import ArgumentParser
import Foundation

struct Playlist: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage playlists.",
        subcommands: [
            PlaylistBrowse.self,
            PlaylistList.self,
            PlaylistTracks.self,
            PlaylistCreate.self,
            PlaylistDelete.self,
            PlaylistAdd.self,
            PlaylistRemove.self,
            PlaylistShare.self,
            PlaylistTemp.self,
            PlaylistCreateFrom.self,
            PlaylistCleanup.self,
        ],
        defaultSubcommand: PlaylistBrowse.self
    )
}

struct PlaylistBrowse: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "browse", abstract: "Browse playlists interactively.")

    func run() throws {
        guard isTTY() else {
            try listPlaylists(json: false)
            return
        }

        let backend = AppleScriptBackend()
        let result = try syncRun {
            try await backend.runMusic("""
                set output to ""
                repeat with p in (every user playlist)
                    if output is not "" then set output to output & linefeed
                    set output to output & name of p
                end repeat
                return output
            """)
        }
        let names = result.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !names.isEmpty else {
            print("No playlists found.")
            return
        }

        // Track data cache — fetches ALL tracks for scrollable browsing
        var trackCache: [Int: PlaylistPreview] = [:]

        let onTracks: (Int) -> PlaylistPreview? = { idx in
            if let cached = trackCache[idx] { return cached }
            let plName = names[idx]
            let escapedPlName = plName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            guard let trackResult = try? syncRun({
                try await backend.runMusic("""
                    set trackList to every track of playlist "\(escapedPlName)"
                    set output to ""
                    set i to 1
                    set total to count of trackList
                    repeat with t in trackList
                        if i > 200 then exit repeat
                        if output is not "" then set output to output & linefeed
                        set output to output & name of t & " — " & artist of t
                        set i to i + 1
                    end repeat
                    return (total as text) & "|" & output
                """)
            }) else { return nil }
            let trimmed = trackResult.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: "|", maxSplits: 1)
            let count = Int(parts.first ?? "0") ?? 0
            let trackLines = parts.count > 1
                ? String(parts[1]).components(separatedBy: "\n")
                : []
            let preview = PlaylistPreview(name: plName, trackCount: count, tracks: trackLines)
            trackCache[idx] = preview
            return preview
        }

        // Batched metadata fetch for a set of playlist indices.
        // Returns: index -> (count, durationSec, isSmart, specialKind)
        let onMeta: ([Int]) -> [Int: (Int, Int, Bool, String)] = { indices in
            guard !indices.isEmpty else { return [:] }
            var clauses = ""
            for idx in indices where idx >= 0 && idx < names.count {
                let esc = escapeAppleScriptString(names[idx])
                clauses += """
                set p to playlist "\(esc)"
                set output to output & "\(idx)|" & (count of tracks of p) & "|" & (duration of p) & "|" & (smart of p) & "|" & (special kind of p as text) & linefeed

                """
            }
            guard let result = try? syncRun({
                try await backend.runMusic("""
                    set output to ""
                    \(clauses)
                    return output
                """)
            }) else { return [:] }
            var out: [Int: (Int, Int, Bool, String)] = [:]
            for line in result.split(separator: "\n") {
                let f = line.split(separator: "|", maxSplits: 4).map(String.init)
                guard f.count == 5, let idx = Int(f[0]) else { continue }
                let count = Int(f[1]) ?? 0
                let dur = Int(Double(f[2]) ?? 0)
                let smart = f[3].trimmingCharacters(in: .whitespaces) == "true"
                out[idx] = (count, dur, smart, f[4].trimmingCharacters(in: .whitespaces))
            }
            return out
        }

        // Light preview: first 8 "Title — Artist" lines for one playlist.
        var previewCacheLight: [Int: [String]] = [:]
        let onPreview: (Int) -> [String]? = { idx in
            if let c = previewCacheLight[idx] { return c }
            guard idx >= 0, idx < names.count else { return nil }
            let esc = escapeAppleScriptString(names[idx])
            guard let res = try? syncRun({
                try await backend.runMusic("""
                    set output to ""
                    set i to 1
                    repeat with t in (every track of playlist "\(esc)")
                        if i > 8 then exit repeat
                        if output is not "" then set output to output & linefeed
                        set output to output & name of t & " \u{2014} " & artist of t
                        set i to i + 1
                    end repeat
                    return output
                """)
            }) else { return nil }
            let lines = res.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").map(String.init)
            previewCacheLight[idx] = lines
            return lines
        }

        var browserState: BrowserState? = nil

        while true {
            let result = runPlaylistBrowser(
                playlists: names,
                onMeta: onMeta,
                onPreview: onPreview,
                onTracks: onTracks,
                savedState: browserState
            )

            switch result {
            case .playTrack(let plIdx, let trIdx, let ctx, let state):
                browserState = state
                let plName = names[plIdx]
                let escapedPlName2 = plName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                _ = try syncRun {
                    try await backend.runMusic("play track \(trIdx + 1) of playlist \"\(escapedPlName2)\"")
                }
                let npResult = runNowPlayingWithContext(ctx)
                if case .quit = npResult { return }
                // .back -> loop continues, browser restores state

            case .playPlaylist(let idx, let ctx, let state):
                browserState = state
                let plName = names[idx].replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                _ = try syncRun { try await backend.runMusic("set shuffle enabled to false") }
                _ = try syncRun { try await backend.runMusic("play playlist \"\(plName)\"") }
                let npResult = runNowPlayingWithContext(ctx)
                if case .quit = npResult { return }

            case .shufflePlaylist(let idx, let ctx, let state):
                browserState = state
                let plName = names[idx].replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                _ = try syncRun { try await backend.runMusic("set shuffle enabled to true") }
                _ = try syncRun { try await backend.runMusic("play playlist \"\(plName)\"") }
                let npResult = runNowPlayingWithContext(ctx)
                if case .quit = npResult { return }

            case .nowPlaying(let ctx, let state):
                browserState = state
                let npResult = runNowPlayingWithContext(ctx)
                if case .quit = npResult { return }

            case .quit:
                return
            }
        }
    }
}

struct PlaylistList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List playlists.")
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        try listPlaylists(json: json)
    }
}

struct PlaylistTracks: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tracks", abstract: "List tracks in a playlist.")
    @Argument(help: "Playlist name") var name: String
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        try showPlaylistTracks(name: name, json: json)
    }
}

// MARK: - Shared logic (callable without ArgumentParser)

func listPlaylists(json: Bool) throws {
    let auth = AuthManager()
    if let devToken = try? auth.requireDeveloperToken(), let userToken = auth.userToken() {
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let (data, status) = try syncRun { try await api.get("/v1/me/library/playlists?limit=100") }
        if (200...299).contains(status) {
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let items = parsed?["data"] as? [[String: Any]] ?? []
            let playlists: [[String: Any]] = items.map { item in
                let attrs = item["attributes"] as? [String: Any] ?? [:]
                return ["id": item["id"] as? String ?? "", "name": attrs["name"] as? String ?? ""]
            }
            if json {
                let output = OutputFormat(mode: .json)
                print(output.render(["playlists": playlists]))
            } else {
                for pl in playlists { print(pl["name"] as? String ?? "") }
            }
            return
        }
    }

    // Fallback to AppleScript
    let backend = AppleScriptBackend()
    let result = try syncRun {
        try await backend.runMusic("get name of every playlist")
    }
    let names = result.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }

    if json {
        let output = OutputFormat(mode: .json)
        print(output.render(["playlists": names.map { ["name": $0] }]))
    } else {
        for name in names { print(name) }
    }
}

func showPlaylistTracks(name: String, json: Bool) throws {
    let auth = AuthManager()
    if let devToken = try? auth.requireDeveloperToken(), let userToken = auth.userToken() {
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let (listData, listStatus) = try syncRun { try await api.get("/v1/me/library/playlists?limit=100") }
        if (200...299).contains(listStatus) {
            let parsed = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
            let items = parsed?["data"] as? [[String: Any]] ?? []
            if let match = items.first(where: {
                let attrs = $0["attributes"] as? [String: Any] ?? [:]
                return (attrs["name"] as? String ?? "") == name
            }), let plId = match["id"] as? String {
                let (trackData, trackStatus) = try syncRun {
                    try await api.get("/v1/me/library/playlists/\(plId)/tracks")
                }
                if (200...299).contains(trackStatus) {
                    let trackParsed = try JSONSerialization.jsonObject(with: trackData) as? [String: Any]
                    let trackItems = trackParsed?["data"] as? [[String: Any]] ?? []
                    let tracks: [[String: Any]] = trackItems.enumerated().map { (i, item) in
                        let attrs = item["attributes"] as? [String: Any] ?? [:]
                        return [
                            "number": i + 1,
                            "track": attrs["name"] as? String ?? "Unknown",
                            "artist": attrs["artistName"] as? String ?? "Unknown",
                            "album": attrs["albumName"] as? String ?? "",
                            "catalogId": (item["attributes"] as? [String: Any])?["playParams"] as? [String: Any] != nil
                                ? ((item["attributes"] as? [String: Any])?["playParams"] as? [String: Any])?["catalogId"] as? String ?? ""
                                : ""
                        ]
                    }
                    let cache = ResultCache()
                    let songResults = tracks.map { t in
                        SongResult(
                            index: t["number"] as! Int,
                            title: t["track"] as! String,
                            artist: t["artist"] as! String,
                            album: t["album"] as! String,
                            catalogId: t["catalogId"] as? String ?? ""
                        )
                    }
                    try? cache.writeSongs(songResults)
                    if json {
                        let output = OutputFormat(mode: .json)
                        print(output.render(["playlist": name, "tracks": tracks]))
                    } else {
                        for t in tracks {
                            print("\(t["number"]!). \(t["track"]!) — \(t["artist"]!) [\(t["album"]!)]")
                        }
                    }
                    return
                }
            }
        }
    }

    // Fallback to AppleScript
    let backend = AppleScriptBackend()
    let result = try syncRun {
        try await backend.runMusic("""
            set trackList to every track of playlist "\(escapeAppleScriptString(name))"
            set output to ""
            set i to 1
            repeat with t in trackList
                if output is not "" then set output to output & linefeed
                set output to output & i & "|" & name of t & "|" & artist of t & "|" & album of t
                set i to i + 1
            end repeat
            return output
        """)
    }
    let lines = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")

    let parsedTracks: [(num: Int, title: String, artist: String, album: String)] = lines.compactMap { line in
        let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
        guard parts.count >= 4 else { return nil }
        return (num: Int(parts[0]) ?? 0, title: parts[1], artist: parts[2], album: parts[3])
    }

    let cache = ResultCache()
    let songResults = parsedTracks.map { t in
        SongResult(index: t.num, title: t.title, artist: t.artist, album: t.album, catalogId: "")
    }
    try? cache.writeSongs(songResults)

    if json {
        let tracks: [[String: Any]] = parsedTracks.map { t in
            ["number": t.num, "track": t.title, "artist": t.artist, "album": t.album]
        }
        let output = OutputFormat(mode: .json)
        print(output.render(["playlist": name, "tracks": tracks]))
    } else {
        for t in parsedTracks {
            print("\(t.num). \(t.title) — \(t.artist) [\(t.album)]")
        }
    }
}

struct PlaylistCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a playlist.")
    @Argument(help: "Playlist name") var name: String
    @Argument(help: "Result indices to add (from last search/similar)") var indices: [Int] = []
    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let backend = AppleScriptBackend()

        let body: [String: Any] = ["attributes": ["name": name]]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (_, status) = try syncRun { try await api.post("/v1/me/library/playlists", body: bodyData) }
        guard (200...299).contains(status) else {
            throw APIError.requestFailed(status)
        }

        if indices.isEmpty {
            print("Created playlist '\(name)'.")
            return
        }

        let cache = ResultCache()
        var addedCount = 0
        var ids: [String] = []
        for idx in indices {
            if let song = try? cache.lookupSong(index: idx) {
                ids.append(song.catalogId)
            }
        }

        if !ids.isEmpty {
            try syncRun { try await api.addToLibrary(songIDs: ids) }
            withStatus("Syncing library...") {
                try! syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
            }

            let total = indices.count
            var count = 0
            for idx in indices {
                if let song = try? cache.lookupSong(index: idx) {
                    let et = song.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let ea = song.artist.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    _ = try? syncRun {
                        try await backend.runMusic("""
                            set results to (every track of playlist "Library" whose name is "\(et)" and artist is "\(ea)")
                            if (count of results) = 0 then
                                set results to (every track of playlist "Library" whose name contains "\(et)" and artist contains "\(ea)")
                            end if
                            if (count of results) > 0 then
                                duplicate item 1 of results to playlist "\(escapeAppleScriptString(name))"
                            end if
                        """)
                    }
                    addedCount += 1
                    count += 1
                    updateStatus("Adding tracks... \(count)/\(total)")
                    print("  + \(song.title) — \(song.artist)")
                }
            }
            clearStatus()
        }

        print("Created '\(name)' with \(addedCount) tracks.")
    }
}

struct PlaylistDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a playlist.")
    @Argument(help: "Playlist name") var name: String
    func run() throws {
        let backend = AppleScriptBackend()
        let escName = escapeAppleScriptString(name)
        _ = try syncRun {
            try await backend.runMusic("delete playlist \"\(escName)\"")
        }
        print("Deleted playlist '\(name)'.")
    }
}

struct PlaylistAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add track(s) to playlist.")
    @Argument(help: "Playlist name") var playlist: String
    @Argument(help: "Song title or result indices") var items: [String] = []
    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let backend = AppleScriptBackend()

        let ints = items.compactMap { Int($0) }
        if ints.count == items.count && !ints.isEmpty {
            let cache = ResultCache()
            var ids: [String] = []
            var songs: [SongResult] = []
            for idx in ints {
                if let song = try? cache.lookupSong(index: idx) {
                    ids.append(song.catalogId)
                    songs.append(song)
                }
            }

            if !ids.isEmpty {
                try syncRun { try await api.addToLibrary(songIDs: ids) }
                withStatus("Syncing library...") {
                    try! syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
                }

                let total = songs.count
                var count = 0
                for song in songs {
                    let et = song.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let ea = song.artist.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    _ = try? syncRun {
                        try await backend.runMusic("""
                            set results to (every track of playlist "Library" whose name is "\(et)" and artist is "\(ea)")
                            if (count of results) = 0 then
                                set results to (every track of playlist "Library" whose name contains "\(et)" and artist contains "\(ea)")
                            end if
                            if (count of results) > 0 then
                                duplicate item 1 of results to playlist "\(escapeAppleScriptString(playlist))"
                            end if
                        """)
                    }
                    count += 1
                    updateStatus("Adding tracks... \(count)/\(total)")
                    print("  + \(song.title) — \(song.artist)")
                }
                clearStatus()
                print("Added \(songs.count) track(s) to '\(playlist)'.")
            }
            return
        }

        let title = items.first ?? ""
        let artist: String? = items.count > 1 ? items.dropFirst().joined(separator: " ") : nil

        var searchQuery = title
        if let artist = artist { searchQuery += " \(artist)" }

        let foundSongs = try syncRun { try await api.searchSongs(query: searchQuery, limit: 1) }
        guard let song = foundSongs.first else {
            print("No results for '\(searchQuery)'")
            throw ExitCode.failure
        }
        print("Found: \(song.title) — \(song.artist)")

        try syncRun { try await api.addToLibrary(songIDs: [song.id]) }
        withStatus("Syncing library...") {
            try! syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
        }

        let escapedTitle = song.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedArtist = song.artist.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = try syncRun {
            try await backend.runMusic("""
                set results to (every track of playlist "Library" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
                if (count of results) = 0 then
                    set results to (every track of playlist "Library" whose name contains "\(escapedTitle)" and artist contains "\(escapedArtist)")
                end if
                if (count of results) > 0 then
                    duplicate item 1 of results to playlist "\(escapeAppleScriptString(playlist))"
                end if
            """)
        }
        print("Added to '\(playlist)'.")
    }
}

struct PlaylistRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a track from a playlist.")
    @Argument(help: "Playlist name") var playlist: String
    @Argument(help: "Track name to remove") var title: String
    func run() throws {
        let backend = AppleScriptBackend()
        let escPlaylist = escapeAppleScriptString(playlist)
        let escTitle = escapeAppleScriptString(title)
        _ = try syncRun {
            try await backend.runMusic("""
                set t to (first track of playlist "\(escPlaylist)" whose name contains "\(escTitle)")
                delete t
            """)
        }
        print("Removed '\(title)' from '\(playlist)'.")
    }
}

struct PlaylistShare: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "share", abstract: "Share a playlist.")
    @Argument(help: "Playlist name") var name: String
    @Option(name: .long, help: "Send via iMessage to phone/contact") var imessage: String?
    @Option(name: .long, help: "Send via email") var email: String?
    func run() throws {
        let backend = AppleScriptBackend()
        let escName = escapeAppleScriptString(name)
        let trackList = try syncRun {
            try await backend.runMusic("""
                set trackList to every track of playlist "\(escName)"
                set output to ""
                repeat with t in trackList
                    if output is not "" then set output to output & ", "
                    set output to output & name of t & " - " & artist of t
                end repeat
                return output
            """)
        }
        let message = "Check out my playlist '\(name)': \(trackList.trimmingCharacters(in: .whitespacesAndNewlines))"

        if let recipient = imessage {
            let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            _ = try syncRun {
                try await backend.run("""
                    tell application "Messages"
                        set targetService to 1st account whose service type = iMessage
                        set targetBuddy to participant "\(escapeAppleScriptString(recipient))" of targetService
                        send "\(escaped)" to targetBuddy
                    end tell
                """)
            }
            print("Sent to \(recipient) via iMessage.")
        } else if let addr = email {
            let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            _ = try syncRun {
                try await backend.run("""
                    tell application "Mail"
                        set newMessage to make new outgoing message with properties {subject:"Playlist: \(escName)", content:"\(escaped)", visible:true}
                        tell newMessage
                            make new to recipient at end of to recipients with properties {address:"\(escapeAppleScriptString(addr))"}
                        end tell
                        activate
                    end tell
                """)
            }
            print("Email composed to \(addr).")
        } else {
            print("Specify --imessage or --email")
            throw ExitCode.failure
        }
    }
}

struct PlaylistTemp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "temp", abstract: "Create a temporary playlist, play it, auto-delete on cleanup.")
    @Argument(help: "Alternating title artist pairs: \"Song1\" \"Artist1\" \"Song2\" \"Artist2\"") var items: [String]
    func run() throws {
        guard items.count >= 2, items.count % 2 == 0 else {
            print("Provide alternating title artist pairs: temp \"Song\" \"Artist\" \"Song2\" \"Artist2\"")
            throw ExitCode.failure
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let name = "__temp__\(timestamp)"
        let backend = AppleScriptBackend()

        _ = try syncRun {
            try await backend.runMusic("make new playlist with properties {name:\"\(escapeAppleScriptString(name))\"}")
        }

        for i in stride(from: 0, to: items.count, by: 2) {
            let title = items[i].replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let artist = items[i + 1].replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            _ = try syncRun {
                try await backend.runMusic("""
                    set results to (every track of playlist "Library" whose name is "\(title)" and artist is "\(artist)")
                    if (count of results) = 0 then
                        set results to (every track of playlist "Library" whose name contains "\(title)" and artist contains "\(artist)")
                    end if
                    if (count of results) > 0 then
                        duplicate item 1 of results to playlist "\(escapeAppleScriptString(name))"
                    end if
                """)
            }
        }

        // Split into separate calls to avoid parameter error -50
        _ = try syncRun {
            try await backend.runMusic("set shuffle enabled to true")
        }
        _ = try syncRun {
            try await backend.runMusic("play playlist \"\(escapeAppleScriptString(name))\"")
        }
        print("Playing temp playlist with \(items.count / 2) tracks. Run `music playlist cleanup` when done.")
    }
}

struct PlaylistCreateFrom: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create-from", abstract: "Create playlist from title/artist pairs.")
    @Argument(help: "Alternating title artist title artist...") var items: [String]
    @Option(name: .long, help: "Playlist name") var name: String = "New Playlist"
    func run() throws {
        guard items.count >= 2, items.count % 2 == 0 else {
            print("Provide alternating title artist pairs: create-from \"Song\" \"Artist\" \"Song2\" \"Artist2\"")
            throw ExitCode.failure
        }

        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let backend = AppleScriptBackend()

        _ = try syncRun {
            try await backend.runMusic("make new playlist with properties {name:\"\(escapeAppleScriptString(name))\"}")
        }

        var added: [(title: String, artist: String)] = []
        var failed: [(title: String, artist: String)] = []
        for i in stride(from: 0, to: items.count, by: 2) {
            let title = items[i]
            let artist = items[i + 1]
            do {
                let songs = try syncRun { try await api.searchSongs(query: "\(title) \(artist)", limit: 1) }
                if let song = songs.first {
                    do {
                        try syncRun { try await api.addToLibrary(songIDs: [song.id]) }
                        added.append((title: song.title, artist: song.artist))
                        print("  + \(song.title) — \(song.artist)")
                    } catch {
                        failed.append((title: title, artist: artist))
                        print("  ✗ Failed to add: \(title) — \(artist)")
                    }
                } else {
                    failed.append((title: title, artist: artist))
                    print("  ✗ Not found: \(title) — \(artist)")
                }
            } catch {
                failed.append((title: title, artist: artist))
                print("  ✗ Search failed: \(title) — \(artist)")
            }
        }

        guard !added.isEmpty else {
            print("No tracks were added. Playlist '\(name)' is empty.")
            return
        }

        // Wait for library sync then add to playlist
        withStatus("Syncing library...") {
            try! syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
        }

        let total = added.count
        var count = 0
        for track in added {
            let escapedTitle = track.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let escapedArtist = track.artist.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            _ = try syncRun {
                try await backend.runMusic("""
                    set results to (every track of playlist "Library" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
                    if (count of results) = 0 then
                        set results to (every track of playlist "Library" whose name contains "\(escapedTitle)" and artist contains "\(escapedArtist)")
                    end if
                    if (count of results) > 0 then
                        duplicate item 1 of results to playlist "\(escapeAppleScriptString(name))"
                    end if
                """)
            }
            count += 1
            updateStatus("Adding tracks... \(count)/\(total)")
        }
        clearStatus()

        print("Created '\(name)' with \(added.count) tracks.")
        if !failed.isEmpty {
            print("Failed (\(failed.count)): \(failed.map { "\($0.title) — \($0.artist)" }.joined(separator: ", "))")
        }
    }
}

struct PlaylistCleanup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cleanup", abstract: "Delete all temp playlists.")
    func run() throws {
        let backend = AppleScriptBackend()
        let result = try syncRun {
            try await backend.runMusic("""
                set pNames to name of every playlist
                set deleted to 0
                repeat with p in pNames
                    if p starts with "__temp__" then
                        delete playlist p
                        set deleted to deleted + 1
                    end if
                end repeat
                return deleted
            """)
        }
        let count = result.trimmingCharacters(in: .whitespacesAndNewlines)
        print("Cleaned up \(count) temp playlist(s).")
    }
}

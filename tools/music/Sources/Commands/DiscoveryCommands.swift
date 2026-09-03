import ArgumentParser
import Foundation

struct Similar: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find similar tracks.")
    // Variadic, like Search/Play: `music similar Hotel California` is one title.
    // (Two separate positionals parsed that as title="Hotel" artist="California".)
    @Argument(help: "Title (omit for current track)") var query: [String] = []
    @Option(name: .long, help: "Artist to narrow the match") var artist: String?
    @Option(name: .long, help: "Max results") var limit: Int = 10
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        var searchQuery: String
        if !query.isEmpty {
            let title = query.joined(separator: " ")
            searchQuery = artist != nil ? "\(title) \(artist!)" : title
        } else {
            let backend = AppleScriptBackend()
            let result = try syncRun {
                try await backend.runMusic("return name of current track & \" \" & artist of current track")
            }
            searchQuery = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let songs = try syncRun { try await api.searchSongs(query: searchQuery, limit: 1) }
        guard let song = songs.first else {
            print("Could not find '\(searchQuery)'")
            throw ExitCode.failure
        }

        var similar: [CatalogSong] = []

        // Search for more songs by the same artist (excluding the seed song)
        let artistSongs = try syncRun { try await api.searchSongs(query: song.artist, limit: limit + 5) }
        similar += artistSongs.filter { $0.id != song.id }

        // If not enough results, also search by song title for covers/remixes
        if similar.count < limit {
            let titleSongs = try syncRun { try await api.searchSongs(query: song.title, limit: limit) }
            let existingIDs = Set(similar.map { $0.id } + [song.id])
            similar += titleSongs.filter { !existingIDs.contains($0.id) }
        }

        let cache = ResultCache()
        let songResults = similar.prefix(limit).enumerated().map { (i, song) in
            SongResult(index: i + 1, title: song.title, artist: song.artist, album: song.album, catalogId: song.id)
        }
        try? cache.writeSongs(songResults)

        let output = OutputFormat(mode: json ? .json : .human)
        if json {
            print(output.render(similar.prefix(limit).map { $0.toDict() }))
        } else if isBareInvocation(command: "similar") && isTTY() {
            var items = Array(similar.prefix(limit)).map {
                MultiSelectItem(label: "\($0.title) — \($0.artist)", sublabel: $0.album, selected: false)
            }
            let songsCopy = Array(similar.prefix(limit))
            let action = runMultiSelectList(
                title: "Similar to: \(song.title) — \(song.artist)",
                items: &items,
                actions: [
                    (key: "p", label: "play", action: { cursor, _ in .played(cursor) }),
                    (key: "s", label: "shuffle", action: { cursor, selected in
                        .shuffled(selected.isEmpty ? [cursor] : selected)
                    }),
                    (key: "a", label: "add", action: { cursor, selected in
                        .addedToLibrary(selected.isEmpty ? [cursor] : selected)
                    }),
                    (key: "c", label: "create playlist", action: { _, selected in
                        .createPlaylist(selected)
                    }),
                ]
            )
            try handleSongAction(action, songs: songsCopy, api: api)
        } else {
            print("Similar to: \(song.title) — \(song.artist)")
            for (i, s) in similar.prefix(limit).enumerated() {
                print("\(i + 1). \(s.title) — \(s.artist) [\(s.album)]")
            }
        }
    }
}

struct Suggest: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Suggest tracks based on what's playing.")
    @Argument(help: "Number of suggestions") var count: Int = 10
    @Option(name: .long, help: "Base suggestions on a playlist") var from: String?
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        var seedSongIDs: [String] = []

        if let playlistName = from {
            let (listData, _) = try syncRun { try await api.get("/v1/me/library/playlists?limit=100") }
            let parsed = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
            let items = parsed?["data"] as? [[String: Any]] ?? []
            if let match = items.first(where: {
                let attrs = $0["attributes"] as? [String: Any] ?? [:]
                return (attrs["name"] as? String ?? "") == playlistName
            }), let plId = match["id"] as? String {
                let (trackData, _) = try syncRun { try await api.get("/v1/me/library/playlists/\(plId)/tracks") }
                let trackParsed = try JSONSerialization.jsonObject(with: trackData) as? [String: Any]
                let trackItems = trackParsed?["data"] as? [[String: Any]] ?? []
                for item in trackItems.prefix(5) {
                    let attrs = item["attributes"] as? [String: Any] ?? [:]
                    let name = attrs["name"] as? String ?? ""
                    let artist = attrs["artistName"] as? String ?? ""
                    let found = try syncRun { try await api.searchSongs(query: "\(name) \(artist)", limit: 1) }
                    if let s = found.first { seedSongIDs.append(s.id) }
                }
            }
        } else {
            let backend = AppleScriptBackend()
            let result = try syncRun {
                try await backend.runMusic("return name of current track & (ASCII character 31) & artist of current track")
            }
            if let seed = parseSeedTrack(result) {
                let found = try syncRun { try await api.searchSongs(query: "\(seed.name) \(seed.artist)", limit: 1) }
                if let s = found.first { seedSongIDs.append(s.id) }
            }
        }

        var allSongs: [CatalogSong] = []
        let (recData, recStatus) = try syncRun {
            try await api.get("/v1/me/recommendations?limit=\(count)")
        }
        if (200...299).contains(recStatus) {
            let recJson = try JSONSerialization.jsonObject(with: recData) as? [String: Any]
            let recItems = recJson?["data"] as? [[String: Any]] ?? []
            for item in recItems {
                let relationships = item["relationships"] as? [String: Any] ?? [:]
                let contents = relationships["contents"] as? [String: Any] ?? [:]
                let contentData = contents["data"] as? [[String: Any]] ?? []
                for content in contentData {
                    let attrs = content["attributes"] as? [String: Any] ?? [:]
                    allSongs.append(CatalogSong(
                        id: content["id"] as? String ?? "",
                        title: attrs["name"] as? String ?? "Unknown",
                        artist: attrs["artistName"] as? String ?? "Unknown",
                        album: attrs["albumName"] as? String ?? ""
                    ))
                }
            }
        }

        let seedSet = Set(seedSongIDs)
        let suggestions = allSongs.filter { !seedSet.contains($0.id) }.prefix(count)

        let cache = ResultCache()
        let songResults = suggestions.enumerated().map { (i, song) in
            SongResult(index: i + 1, title: song.title, artist: song.artist, album: song.album, catalogId: song.id)
        }
        try? cache.writeSongs(songResults)

        let output = OutputFormat(mode: json ? .json : .human)
        if json {
            print(output.render(suggestions.map { $0.toDict() }))
        } else if isBareInvocation(command: "suggest") && isTTY() {
            var items = suggestions.map {
                MultiSelectItem(label: "\($0.title) — \($0.artist)", sublabel: $0.album, selected: false)
            }
            let songsCopy = Array(suggestions)
            let action = runMultiSelectList(
                title: "Suggestions",
                items: &items,
                actions: [
                    (key: "p", label: "play", action: { cursor, _ in .played(cursor) }),
                    (key: "s", label: "shuffle", action: { cursor, selected in
                        .shuffled(selected.isEmpty ? [cursor] : selected)
                    }),
                    (key: "a", label: "add", action: { cursor, selected in
                        .addedToLibrary(selected.isEmpty ? [cursor] : selected)
                    }),
                    (key: "c", label: "create playlist", action: { _, selected in
                        .createPlaylist(selected)
                    }),
                ]
            )
            try handleSongAction(action, songs: songsCopy, api: api)
        } else {
            for (i, s) in suggestions.enumerated() {
                print("\(i + 1). \(s.title) — \(s.artist) [\(s.album)]")
            }
        }
    }
}

struct NewReleases: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new-releases", abstract: "Find new releases.")
    @Flag(name: .long, help: "Based on current track") var likeCurrent = false
    @Option(name: .long, help: "From specific artist") var artist: String?
    @Option(name: .long, help: "Max results") var limit: Int = 10
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let sf = auth.storefront()

        var seedArtist: String
        if let artist = artist {
            seedArtist = artist
        } else if likeCurrent {
            let backend = AppleScriptBackend()
            let result = try syncRun {
                try await backend.runMusic("return artist of current track")
            }
            seedArtist = result.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            print("Specify --like-current or --artist")
            throw ExitCode.failure
        }

        let encoded = seedArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seedArtist
        let (artistData, artistStatus) = try syncRun {
            try await api.get("/v1/catalog/\(sf)/search?term=\(encoded)&types=artists&limit=1")
        }

        var releases: [CatalogSong] = []
        if (200...299).contains(artistStatus) {
            let artistJson = try JSONSerialization.jsonObject(with: artistData) as? [String: Any]
            let results = artistJson?["results"] as? [String: Any]
            let artists = results?["artists"] as? [String: Any]
            let artistItems = artists?["data"] as? [[String: Any]] ?? []
            if let artistItem = artistItems.first, let artistId = artistItem["id"] as? String {
                let (albumData, albumStatus) = try syncRun {
                    try await api.get("/v1/catalog/\(sf)/artists/\(artistId)/albums?limit=\(limit)")
                }
                if (200...299).contains(albumStatus) {
                    let albumJson = try JSONSerialization.jsonObject(with: albumData) as? [String: Any]
                    let albumItems = albumJson?["data"] as? [[String: Any]] ?? []
                    for album in albumItems {
                        let attrs = album["attributes"] as? [String: Any] ?? [:]
                        releases.append(CatalogSong(
                            id: album["id"] as? String ?? "",
                            title: attrs["name"] as? String ?? "Unknown",
                            artist: attrs["artistName"] as? String ?? seedArtist,
                            album: attrs["releaseDate"] as? String ?? ""
                        ))
                    }
                }
            }
        }

        let cache = ResultCache()
        let songResults = releases.prefix(limit).enumerated().map { (i, r) in
            SongResult(index: i + 1, title: r.title, artist: r.artist, album: r.album, catalogId: r.id)
        }
        try? cache.writeSongs(songResults)

        let output = OutputFormat(mode: json ? .json : .human)
        if json {
            print(output.render(releases.prefix(limit).map { $0.toDict() }))
        } else {
            for (i, r) in releases.prefix(limit).enumerated() {
                print("\(i + 1). \(r.title) — \(r.artist) [\(r.album)]")
            }
        }
    }
}

func handleSongAction(_ action: MultiSelectAction, songs: [CatalogSong], api: RESTAPIBackend) throws {
    let backend = AppleScriptBackend()
    switch action {
    case .played(let idx):
        let song = songs[idx]
        let result = try syncRun {
            try await backend.runMusic("""
                \(libraryTrackLookupScript(title: song.title, artist: song.artist))
                if (count of results) > 0 then
                    play item 1 of results
                    return "OK"
                else
                    return "NOT_FOUND"
                end if
            """)
        }
        if result.trimmingCharacters(in: .whitespacesAndNewlines) == "NOT_FOUND" {
            try syncRun { try await api.addToLibrary(songIDs: [song.id]) }
            try syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
            _ = playLibraryTrack(backend: backend, title: song.title, artist: song.artist)
        }
        print("Playing: \(song.title) — \(song.artist)")

    case .addedToLibrary(let indices):
        let ids = indices.map { songs[$0].id }
        try syncRun { try await api.addToLibrary(songIDs: ids) }
        print("Added \(ids.count) track(s) to library.")

    case .createPlaylist(let indices):
        guard !indices.isEmpty else {
            print("No tracks selected.")
            return
        }
        let name = "New Playlist \(Int(Date().timeIntervalSince1970) % 100000)"
        // One API call creates and populates — no library detour, no sync sleep.
        _ = try syncRun { try await api.createPlaylist(name: name, songIDs: indices.map { songs[$0].id }) }
        print("Created '\(name)' with \(indices.count) tracks.")

    case .shuffled(let indices):
        guard !indices.isEmpty else {
            print("No tracks selected.")
            return
        }
        let name = tempPlaylistCreationPrefix + "\(Int(Date().timeIntervalSince1970))"
        // Create + populate server-side, then wait (bounded poll, not a blind
        // sleep) for the playlist to sync locally — AppleScript can only play
        // what the local Music.app can see.
        _ = try syncRun { try await api.createPlaylist(name: name, songIDs: indices.map { songs[$0].id }) }
        guard waitForLocalPlaylist(backend: backend, name: name, minTracks: indices.count) else {
            print("Created '\(name)' but it hasn't synced to this Mac yet — try `music play \(name)` in a moment.")
            return
        }
        _ = try syncRun { try await backend.runMusic("set shuffle enabled to true") }
        _ = try syncRun { try await backend.runMusic("play playlist \"\(escapeAppleScriptString(name))\"") }
        print("Shuffling \(indices.count) tracks. Run `music playlist cleanup` when done.")

    case .confirmed, .cancelled:
        break
    }
}

/// Pure parse of the discover seed payload: "name<asFieldSep>artist". The old
/// "|" delimiter split titles like "Intro | Outro" at the wrong place, so the
/// seed search ran on garbage terms. Returns nil when the separator is absent.
func parseSeedTrack(_ raw: String) -> (name: String, artist: String)? {
    let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: asFieldSep, maxSplits: 1, omittingEmptySubsequences: false)
        .map(String.init)
    guard parts.count == 2 else { return nil }
    return (name: parts[0], artist: parts[1])
}

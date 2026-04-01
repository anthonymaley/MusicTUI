import ArgumentParser
import Foundation

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search and add a track to your library, or add to a playlist.")
    @Argument(help: "Search query or result index") var query: [String] = []
    @Option(name: .long, help: "Add by catalog ID directly") var id: String?
    @Option(name: .long, help: "Add to playlist(s)") var to: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        var songToAdd: CatalogSong?
        var trackTitle: String?
        var trackArtist: String?

        if let catalogID = id {
            try syncRun { try await api.addToLibrary(songIDs: [catalogID]) }
            if to.isEmpty {
                print(json ? "{\"added\":\"\(catalogID)\"}" : "Added (id: \(catalogID)).")
                return
            }
            trackTitle = nil
        } else if query.count == 1, let index = Int(query[0]) {
            let cache = ResultCache()
            let song = try cache.lookupSong(index: index)
            songToAdd = CatalogSong(id: song.catalogId, title: song.title, artist: song.artist, album: song.album)
        } else if !query.isEmpty {
            let searchQuery = query.joined(separator: " ")
            let songs = try syncRun { try await api.searchSongs(query: searchQuery, limit: 1) }
            guard let song = songs.first else {
                print("No results for '\(searchQuery)'")
                throw ExitCode.failure
            }
            songToAdd = song
        } else if !to.isEmpty {
            let backend = AppleScriptBackend()
            let result = try syncRun {
                try await backend.runMusic("return name of current track & \"|\" & artist of current track")
            }
            let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            if parts.count >= 2 {
                trackTitle = String(parts[0])
                trackArtist = String(parts[1])
            }
        } else {
            print("Usage: music add <query>, music add <index>, or music add --to <playlist>")
            throw ExitCode.failure
        }

        if let song = songToAdd {
            print("Found: \(song.title) — \(song.artist) [\(song.album)]")
            try syncRun { try await api.addToLibrary(songIDs: [song.id]) }
            trackTitle = song.title
            trackArtist = song.artist

            if to.isEmpty {
                if json {
                    let output = OutputFormat(mode: .json)
                    print(output.render(["added": true, "track": song.title, "artist": song.artist, "id": song.id]))
                } else {
                    print("Added to library.")
                }
                return
            }
        }

        if !to.isEmpty, let title = trackTitle, let artist = trackArtist {
            let backend = AppleScriptBackend()
            let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedArtist = artist.replacingOccurrences(of: "\"", with: "\\\"")

            if songToAdd != nil {
                try syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
            }

            for pl in to {
                _ = try syncRun {
                    try await backend.runMusic("""
                        set results to (every track of playlist "Library" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
                        if (count of results) = 0 then
                            set results to (every track of playlist "Library" whose name contains "\(escapedTitle)" and artist contains "\(escapedArtist)")
                        end if
                        if (count of results) > 0 then
                            duplicate item 1 of results to playlist "\(pl)"
                        end if
                    """)
                }
                print("Added to '\(pl)'.")
            }
        }
    }
}

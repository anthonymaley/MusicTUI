import ArgumentParser
import Foundation

struct Mix: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build a mixed playlist from multiple artists.")
    @Option(name: .long, help: "Comma-separated artist names") var artists: String
    @Option(name: .long, help: "Total track count") var count: Int = 20
    @Option(name: .long, help: "Playlist name") var name: String = "Mix"
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let backend = AppleScriptBackend()

        let artistList = artists.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let perArtist = max(count / artistList.count, 2)

        _ = try syncRun {
            try await backend.runMusic("make new playlist with properties {name:\"\(name)\"}")
        }

        var allSongs: [CatalogSong] = []
        for artist in artistList {
            let songs = try syncRun { try await api.searchSongs(query: artist, limit: perArtist) }
            allSongs.append(contentsOf: songs)
        }

        let ids = allSongs.map(\.id)
        if !ids.isEmpty {
            try syncRun { try await api.addToLibrary(songIDs: ids) }
        }

        // Wait for library sync
        try syncRun { try await Task.sleep(nanoseconds: 3_000_000_000) }

        for song in allSongs {
            _ = try syncRun {
                try await backend.runMusic("""
                    set results to (every track of playlist "Library" whose name contains "\(song.title)" and artist contains "\(song.artist)")
                    if (count of results) > 0 then
                        duplicate item 1 of results to playlist "\(name)"
                    end if
                """)
            }
        }

        let output = OutputFormat(mode: json ? .json : .human)
        if json {
            print(output.render(["playlist": name, "tracks": allSongs.count, "artists": artistList]))
        } else {
            print("Created '\(name)' with \(allSongs.count) tracks from \(artistList.joined(separator: ", ")).")
        }
    }
}

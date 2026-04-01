import ArgumentParser
import Foundation

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search and add a track to your library.")
    @Argument(help: "Search query (title and/or artist)") var query: [String]
    @Option(name: .long, help: "Add by catalog ID directly") var id: String?
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        if let catalogID = id {
            try syncRun { try await api.addToLibrary(songIDs: [catalogID]) }
            print(json ? "{\"added\":\"\(catalogID)\"}" : "Added (id: \(catalogID)).")
            return
        }

        let searchQuery = query.joined(separator: " ")
        let songs = try syncRun { try await api.searchSongs(query: searchQuery, limit: 1) }
        guard let song = songs.first else {
            print("No results for '\(searchQuery)'")
            throw ExitCode.failure
        }

        print("Found: \(song.title) — \(song.artist) [\(song.album)]")
        try syncRun { try await api.addToLibrary(songIDs: [song.id]) }
        if json {
            let output = OutputFormat(mode: .json)
            print(output.render(["added": true, "track": song.title, "artist": song.artist, "id": song.id]))
        } else {
            print("Added to library.")
        }
    }
}
